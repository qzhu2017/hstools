# Core imports
import sys
import time
from collections import OrderedDict
# Library imports
import numpy as np
# Local imports
from .data import log, log_traceback
from . import calc
from . import fileio as fio

test_f = {'sp': calc.spearman_roc,
          'kt': calc.kendall_tau,
          'hd': calc.hdistance}
test_names = {'sp': 'Spearman rank order coefficient',
              'kt': "Kendall's Tau",
              'hd': 'Sigma histogram distance',
              'dv': 'Euclidean distance between invariants'}


def logClosestPair(mat, names):
    np.fill_diagonal(mat, np.inf)
    x = np.nanargmin(mat)
    ind = (x//len(names), x % len(names))
    a = str(names[ind[0]], 'utf-8')
    b = str(names[ind[1]], 'utf-8')
    log('Closest pair: {0}, d= {1:.5f}'.format((a, b), mat[ind]))
    np.fill_diagonal(mat, 0.0)

def logFarthestPair(mat, names):
    x = np.nanargmax(mat)
    ind = (x//len(names), x % len(names))
    a = str(names[ind[0]],'utf-8')
    b = str(names[ind[1]],'utf-8')
    log('Farthest pair: {0}, d= {1:.5f}'.format((a, b), mat[ind]))



def hist_main(args):
    mtest = test_f[args['--test']]
    tname = test_names[args['--test']]
    procs = int(args['--procs'])

    bins = int(args['--bins'])
    save_figs = args['--save-figures']

    if args['<file>']:
        fname = args['<file>']
        if not save_figs:
            log('Not saving figure, so this \
                        command will have no output')
        h, name = fio.proc_file_hist(fname, resolution=bins,
                                     save_figs=save_figs)

    elif args['<dir>']:
        dirname = args['<dir>']
        dendrogram = args['--dendrogram']
        method = args['--method']
        distance = float(args['--distance'])
        try:
            histograms, names = fio.batch_hist(dirname, resolution=bins,
                                               save_figs=save_figs,
                                               procs=procs)
            log('Generating matrix using {0}'.format(tname))
            mat = calc.get_dist_mat(histograms, test=mtest, threads=procs*2)
            clusters = calc.cluster(mat, names, tname, dump=args['--json'],
                                    dendrogram=dendrogram,
                                    method=method,
                                    distance=distance)
            logClosestPair(mat, names)
            logFarthestPair(mat, names)

            if args['--output']:
                fname = args['--output']
                fio.write_mat_file(fname, mat, np.array(names, dtype='S10'), clusters)

            

        except Exception as e:
            log_traceback(e)


def harmonics_main(args):
    mtest = calc.dvalue
    tname = test_names['dv']
    start_time = time.time()
    procs = int(args['--procs'])

    if args['<file>']:
        fname = args['<file>']
        values, cname = fio.proc_file_harmonics(fname)
        coefficients, invariants = values
        log(cname)
        log(coefficients)

    if args['<dir>']:
        dendrogram = args['--dendrogram']
        method = args['--method']
        distance = float(args['--distance'])
        dirname = args['<dir>']
        values, names = fio.batch_harmonics(dirname, procs=procs)
        names = np.array(names, dtype='S10')
        log('Generating matrix using: "{0}"'.format(tname))
        coefficients, invariants = zip(*values)
        mat = calc.get_dist_mat(invariants, test=mtest, threads=procs*2)
        clusters = calc.cluster(mat, names, tname, dendrogram=dendrogram,
                                method=method, distance=distance)

        if args['--output']:
            fname = args['--output']
            fio.write_mat_file(fname, mat, names, clusters)

        logClosestPair(mat, names)
        logFarthestPair(mat, names)


    footer(start_time)


def surface_main(args):
    start_time = time.time()
    procs = int(args['--procs'])

    restrict = not args['--no-restrict']
    order = args['--order-important']
    if args['<file>']:
        fname = args['<file>']
        # Generate the percentage contribution of each element
        cname, formula, contrib_p = fio.proc_file_sa(fname, restrict,
                                                     order=order)
        log('{0} {1}'.format(cname, formula))

        d = OrderedDict(sorted(contrib_p.items(), key=lambda t: t[1]))
        for k, v in iter(d.items()):
            log('{0}: {1:.2%}'.format(k, v))

    elif args['<dir>']:
        dirname = args['<dir>']
        cnames, formulae, contribs = fio.batch_surface(dirname, restrict,
                                                       procs=procs,
                                                       order=order)
        if restrict:
            log("Restricted interactions using CCDC Van Der Waal's Radii")
        # If we are writing to file
        if args['--output']:
            fname = args['--output']
            fio.write_sa_file(fname, cnames, formulae, contribs)
        # Otherwise we are printing to stdout
        else:
            for i in range(len(formulae)):
                formula = formulae[i]
                contrib_p = contribs[i]
                log('Molecular Formula: {0}'.format(formula))
                if not contrib_p:
                    log(' -- Nil--')

                d = OrderedDict(sorted(contrib_p.items(), key=lambda t: t[1]))
                for k, v in iter(d.items()):
                    log('{0}: {1:.2%}'.format(k, v))
    footer(start_time)


def footer(start_time):
    log('Process complete! Took {0:.2} s'.format(time.time() - start_time))
    sys.exit(0)
