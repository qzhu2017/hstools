module HS
    use class_H5file

    use TYPES_MODULE
    use ATOM_MODULE, only: chemical_symbol => chemical_symbol_
    use SYSTEM_MODULE, only: die_if, tonto
    use GAUSSIAN_DATA_MODULE, only: set_indices
    use CIF_MODULE, only: cif_create => create_
    use CLUSTER_MODULE, only: cluster_create => create_, cluster_put => put_, &
        make_info, set_generation_method, fragment_atom_indices, nonfragment_atom_indices
    use MOLECULE_BASE_MODULE, only: create, set_slaterbasis_name, put_atoms_, unsave_, &
        destroy_interpolators, copy_, molecule_destroy => destroy_
    use MOLECULE_CE_MODULE, only: find_CIF_crystal_data_block
    use MOLECULE_PLOT_MODULE
    use MOLECULE_XTAL_MODULE, only: read_CIF_atoms, read_CIF_crystal, create_cluster, &
        create_cluster_for_mol
    use INTERPOLATOR_MODULE, only: interpolator_create => create_, &
        set_table_spacing, set_table_eps, &
        set_domain_mapping, set_interpolation_method
    use ISOSURFACE_MODULE, only: isosurface_create => create_, &
        make_fingerprint_distances, make_fingerprint_face_atoms
    use MAT_REAL_MODULE, only: mat_real_create => create_, mat_real_destroy => destroy_
    use PLOT_GRID_MODULE, only: reset_defaults_, set_defaults_, &
        set_points_widths_origin, use_bcube_with_shape_axes, set_cube_scale_factor
    use REAL_MODULE, only: convert_from
    use SPHERICAL_MODULE, only: spherical_create => create, &
        get_surface_decomposition, is_star_domain, make_invariants
    use VEC_ATOM_MODULE, only: atom_put => put_, vec_atom_create => create_, &
        vec_atom_destroy => destroy_, chemical_formula
    use VEC_CPX_MODULE, vec_cpx_create => create_, vec_cpx_destroy => destroy_
    use VEC_INT_MODULE, only: vec_int_create => create_, vec_int_destroy => destroy_
    use VEC_REAL_MODULE, only: vec_real_create => create_, vec_real_destroy => destroy_
    use VEC_SLATERBASIS_MODULE, only: vec_sb_create => create_, vec_sb_destroy => destroy_
    use VEC_STR_MODULE, only: vec_str_create => create_, vec_str_destroy => destroy_

    use VEC_BASIS_MODULE, only: set_basis_dir => set_library_directory
    use VEC_COPPENSBASIS_MODULE, only: set_coppensbasis_dir => set_library_directory
    use VEC_REAL_MODULE, only: norm, cross
    use VEC_SLATERBASIS_MODULE, only: set_slaterbasis_dir => set_library_directory


    implicit none
    contains

    subroutine init_molecule(m, cif, directory)
        type(MOLECULE_TYPE), intent(inout), pointer :: m
        character(len=512), intent(in) :: cif, directory
        logical(4) :: found

        ! Initialize molecule
        call create(m)
        call set_indices(4)
        m%spin_multiplicity = 1
        m%charge = 0

        ! Set basis_set library folder
        call set_basis_dir(m%basis,directory)
        call set_slaterbasis_dir(m%slaterbasis,directory)
        call set_coppensbasis_dir(m%coppensbasis,directory)

        ! Set Thakkar basis set
        call set_slaterbasis_name(m,"Thakkar")
        ! Create CIF object
        call cif_create(m%cif, cif)

        ! Set CIF to use bond-length normalization
        m%cif%CH_bond_length = 1.083
        m%cif%NH_bond_length = 1.009
        m%cif%OH_bond_length = 0.983
        m%cif%BH_bond_length = 1.180
        call convert_from(m%cif%CH_bond_length,"angstrom")
        call convert_from(m%cif%NH_bond_length,"angstrom")
        call convert_from(m%cif%OH_bond_length,"angstrom")
        call convert_from(m%cif%BH_bond_length,"angstrom")

        ! Find CIF data block
        call find_CIF_crystal_data_block(m,m%cif,found)
        call die_if(tonto,.not. found,"Error: no data block found in the CIF file!")

        ! Read/process CIF
        call read_CIF_atoms(m,m%cif)
        call read_CIF_crystal(m,m%cif)
    end subroutine

    subroutine make_surfaces(m, res, l_max, hdf_file_name)
        type(MOLECULE_TYPE), intent(in), pointer :: m
        type(MOLECULE_TYPE), pointer :: tmp
        real(8), intent(in) :: res
        integer(4), intent(in) :: l_max
        character(len=512) :: hdf_file_name
        character(len=512) :: formula
        integer :: i
        type(H5file) :: dump_file
        ! Initialize cluster for HS
        call cluster_create(m%cluster,m%crystal)
        call set_generation_method(m%cluster, "fragment")
        m%cluster%radius = 0.0d0
        m%cluster%defragment = .true.
        call make_info(m%cluster)
        dump_file = H5file(trim(hdf_file_name))

        do i = 1, m%cluster%n_molecules
            call create(tmp)
            call copy_(tmp, m)

            call create_cluster_for_mol(tmp, i)
            call dump_file%open_group(trim("/"//chemical_formula(tmp%atom, .false.)))
            ! DO STUFF
            call make_surface(tmp, res)

            call describe_surface(tmp, l_max, dump_file)
            write (*, "(A27, I1)") "Surface done for molecule ", i
            call dump_file%close_group
        end do
        call dump_file%close
    end subroutine


    subroutine describe_surface(m, l_max, dump_file)
        type(MOLECULE_TYPE), intent(in), pointer :: m
        integer(4) :: l_max, a, u, code, i, o
        real(8), dimension(3) :: v1, v2, v3
        integer(4), dimension(:), pointer :: d_e_atoms, d_i_atoms, atoms_inside, atoms_outside, in, out => NULL()
        real(8), dimension(:), pointer :: d_e, d_i, d_norm, d_norm_e, d_norm_i => NULL()
        integer(4), dimension(:), pointer :: unit_cell_numbers => NULL()
        character(len=2), dimension(:), pointer :: unit_cell => NULL()! chemical symbols in unit cell
        real(8), dimension(:,:), pointer :: surface_contribution
        type(SPHERICAL_TYPE), pointer :: spherical => NULL()
        integer(4) :: max_atomic_number = 100
        real(8) :: radius, area
        real(8), dimension(:), pointer :: dnorm_invariants, invariants => NULL()
        real(8), dimension(:,:), pointer :: surface => NULL()
        complex(8), dimension(:), pointer :: dnorm_coefficients, coefficients => NULL()
        type(H5file) :: dump_file
        integer(hid_t) :: root

        call vec_int_create(out, size(nonfragment_atom_indices(m%saved%cluster)))
        call vec_int_create(in, size(fragment_atom_indices(m%saved%cluster)))
        in = fragment_atom_indices(m%saved%cluster)
        out = nonfragment_atom_indices(m%saved%cluster)

        ! GET FINGERPRINT DISTANCES (D_E etc)

        call vec_real_create(d_i, m%isosurface%n_pt)
        call vec_real_create(d_e, m%isosurface%n_pt)
        call vec_real_create(d_norm_i, m%isosurface%n_pt)
        call vec_real_create(d_norm_e, m%isosurface%n_pt)
        call vec_real_create(d_norm, m%isosurface%n_pt)

        ! all the d_i etc.
        call make_fingerprint_distances(m%isosurface, &
            d_e, d_i, d_norm_e, &
            d_norm_i, d_norm, &
            in, out, &
            m%isosurface%atom, &
            .true.)

        ! DE .and. DI FACE ATOMS
        call vec_int_create(d_e_atoms,m%isosurface%n_face)
        call vec_int_create(d_i_atoms,m%isosurface%n_face)
        call make_fingerprint_face_atoms(m%isosurface,d_e_atoms,d_i_atoms,in,out)

        ! spherical harmonic decomposition
        call spherical_create(spherical)
        call mat_real_create(surface,m%isosurface%n_pt, 3)

        if (.not. is_star_domain(m%isosurface%point, m%isosurface%point_gradient)) then
            print *, "WARNING: Surface is not a star domain, results might be useless..."
        end if

        ! don't ask me why i transposed this, needs to be sorted out but it's minor
        ! convert to angstroms???
        surface = transpose(m%isosurface%point) * 0.5291772108d0
        radius = get_surface_decomposition(coefficients,  &
            dnorm_coefficients, &
            l_max, 5810, &
            surface, &
            d_norm)


        ! MAKE INVARIANTS (add radius to the end of call to factor in radius as an invariant)   
        call make_invariants(coefficients, l_max, invariants)
        call make_invariants(dnorm_coefficients, l_max, dnorm_invariants)

        ! get the unit cell labels
        call vec_str_create(unit_cell,m%saved%cluster%crystal%n_unit_cell_atoms)
        call vec_int_create(unit_cell_numbers,m%saved%cluster%crystal%n_unit_cell_atoms)

        ! ATOM SYMBOLS IN THE UNIT CELL
        do u = 1, m%saved%cluster%crystal%n_unit_cell_atoms
            a = m%saved%cluster%crystal%asym_atom_for_unit_cell_atom(u)
            unit_cell(u) = trim(chemical_symbol(m%saved%cluster%asymmetric_unit_atom(a)))
            unit_cell_numbers(u) = m%saved%cluster%asymmetric_unit_atom(a)%atomic_number
        end do

        ! ATOMS INSIDE AND OUTSIDE SURFACE
        ! inside
        call vec_int_create(atoms_inside,m%saved%cluster%n_fragment_atoms)
        do a = 1, m%saved%cluster%n_fragment_atoms
            code = m%saved%cluster%occupation_list(a)
            atoms_inside(a) = ibits(code,4*3,19)
        end do

        ! outside
        call vec_int_create(atoms_outside,m%saved%cluster%n_atoms - m%saved%cluster%n_fragment_atoms)
        do a = m%saved%cluster%n_fragment_atoms+1, m%saved%cluster%n_atoms
            code = m%saved%cluster%occupation_list(a)
            atoms_outside(a - m%saved%cluster%n_fragment_atoms) = ibits(code,4*3,19)
        end do

        ! all the surface contribution code
        call mat_real_create(surface_contribution, max_atomic_number, max_atomic_number)
        surface_contribution = 0.0

        ! Make atom SA contribution matrix
        do a = 1, size(d_i_atoms)
            i = unit_cell_numbers(atoms_inside(d_i_atoms(a)))
            o = unit_cell_numbers(atoms_outside(d_e_atoms(a)))

            ! if < dnorm, then add to contribution
            v1 = m%isosurface%point(:, m%isosurface%face(1, a))
            v2 = m%isosurface%point(:, m%isosurface%face(2, a))
            v3 = m%isosurface%point(:, m%isosurface%face(3, a))

            area = norm(cross(v1 - v3, v2 - v3)) / 2.0

            surface_contribution(i, o) = surface_contribution(i, o) + area
        end do


        ! SURFACE
        call dump_file%write("vertices", m%isosurface%point)
        call dump_file%write("indices", m%isosurface%face)
        call dump_file%write("atoms_inside_surface", atoms_inside)
        call dump_file%write("atoms_outside_surface", atoms_outside)
        call dump_file%write("d_e_face_atoms", d_e_atoms)
        call dump_file%write("d_i_face_atoms", d_i_atoms)
        call dump_file%write("surface_contribution", surface_contribution)

        ! SURFACE PROPERTIES
        call dump_file%write("radius", [radius])
        call dump_file%write("d_e", d_e)
        call dump_file%write("d_i", d_i)
        call dump_file%write("d_norm", d_norm)
        call dump_file%write("d_norm_i", d_norm_i)
        call dump_file%write("d_norm_e", d_norm_e)

        ! CIF INFO
        call dump_file%write("unit_cell", unit_cell)

        ! SPHERICAL HARMONICS STUFF
        call dump_file%write("coefficients",coefficients)
        call dump_file%write("dnorm_coefficients", dnorm_coefficients)
        call dump_file%write("invariants", invariants)
        call dump_file%write("dnorm_invariants", dnorm_invariants)

        ! CLEANUP ALL THE HEAP ALLOCATED ARRAYS
        call vec_cpx_destroy(coefficients)
        call vec_real_destroy(invariants)
        call vec_cpx_destroy(dnorm_coefficients)
        call vec_real_destroy(dnorm_invariants)
        call vec_real_destroy(d_norm_e)
        call vec_real_destroy(d_norm_i)
        call vec_real_destroy(d_norm)
        call vec_real_destroy(d_i)
        call vec_real_destroy(d_e)
        call vec_int_destroy(out)
        call vec_int_destroy(in)


    end subroutine

    subroutine make_surface(m, res)
        type(MOLECULE_TYPE), intent(in), pointer :: m
        real(8), intent(in) :: res

        ! Initialize interpolator for HS
        call cluster_create(m%cluster, m%crystal)
        call set_generation_method(m%cluster, "for_hirshfeld_surface")
        m%cluster%atom_density_cutoff = 1.0e-8
        m%cluster%defragment = .false.
        call make_info(m%cluster)
        call create_cluster(m)

        call interpolator_create(m%interpolator)
        call set_interpolation_method(m%interpolator,"linear")
        call set_domain_mapping(m%interpolator,"sqrt")
        call set_table_eps(m%interpolator,1.0d-10)
        call set_table_spacing(m%interpolator,1.0d-1)
        call destroy_interpolators(m)

        ! Create CX_isosurface
        call isosurface_create(m%isosurface, m%atom)
        call set_defaults_(m%isosurface%plot_grid,m%saved%atom)
        m%isosurface%plot_grid%n_x = 3
        call set_points_widths_origin(m%isosurface%plot_grid)

        ! Initialize CX_isosurface
        m%isosurface%property = "stockholder_weight"
        m%isosurface%triangulation_method = "recursive_marching_cube"

        m%isosurface%iso_value = 0.5
        m%isosurface%surface_property = "none"
        m%isosurface%minimum_scan_division = 1
        m%isosurface%voxel_proximity_factor = 5

        m%isosurface%CX_output_distance_properties = .true.
        m%isosurface%CX_output_shape_properties = .true.

        ! Initialize CX_isosurface.plot_grid
        call reset_defaults_(m%isosurface%plot_grid) ! don't reset bounding box or axes
        call use_bcube_with_shape_axes(m%isosurface%plot_grid)
        call set_cube_scale_factor(m%isosurface%plot_grid, 1.0d0)


        ! Desired separation is essentially the resolution of the calculated surface
        m%isosurface%plot_grid%desired_separation = res

        ! Make isosurface
        call isosurface_plot_(m)

    end subroutine


end module
