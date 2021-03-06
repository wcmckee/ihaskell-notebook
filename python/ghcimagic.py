# -*- coding: utf-8 -*-
"""
===========
ghcimagic
===========

Magics for interacting with GHCI via ghci2py

.. note::

  The ``ghci2py`` module needs to be installed separately.

{GHCI_DOC}

{GHCI_PULL_DOC}

{GHCI_PUSH_DOC}

Usage
=====

``%ghci``

"""

#-----------------------------------------------------------------------------
#  Copyright (C) 2013 Rogan Creswick and Benjamin Jones
#
#  Distributed under the terms of the BSD License.  The full license is in
#  the file COPYING, distributed as part of this software.
#-----------------------------------------------------------------------------

import ghci2py

from IPython.core.displaypub import publish_display_data
from IPython.core.magic import (Magics, magics_class, line_magic,
                                line_cell_magic, cell_magic,
                                needs_local_scope)
from IPython.testing.skipdoctest import skip_doctest
from IPython.core.magic_arguments import (
    argument, magic_arguments, parse_argstring
)
from IPython.utils.py3compat import unicode_to_str


class GhciMagicError:
    pass


@magics_class
class GhciMagics(Magics):
    """A set of magics useful for interactive work with Octave via oct2py.
    """
    def __init__(self, shell):
        """
        Parameters
        ----------
        shell : IPython shell

        """
        super(GhciMagics, self).__init__(shell)
        self._ghci = ghci2py.Ghci2Py()

        # Allow publish_display_data to be overridden for
        # testing purposes.
        self._publish_display_data = publish_display_data

    @skip_doctest
    @line_magic
    def ghci_push(self, line):
        '''
        Line-level magic that pushes a variable to ghci.

        `line` should be made up of whitespace separated variable names in the
        IPython namespace::

            In [7]: x = 1

            In [8]: %ghci_push x

            In [11]: %ghci x + 2
            Out[11]: 3

        '''
        inputs = line.split(' ')
        for input in inputs:
            input = unicode_to_str(input)
            self._ghci.put(input, self.shell.user_ns[input])

    @skip_doctest
    @line_magic
    def ghci_pull(self, line):
        '''
        Line-level magic that pulls a variable from ghci.

            In [18]: _ = %ghci let x = [1, 2, 3, 4]

            In [19]: %ghci_pull x

            In [20]: x
            Out[20]: [1, 2, 3, 4]

            In [21]: _ = %ghci let y = "hello"

            In [22]: %ghci_pull y

            In [23]: y
            Out[23]: 'hello'

        '''
        outputs = line.split(' ')
        for output in outputs:
            output = unicode_to_str(output)
            self.shell.push({output: self._ghci.get(output)})

    @skip_doctest
    @magic_arguments()
    @argument(
        '-v', '--verbose', action='store_true',
        help='turn verbosity up')
    @cell_magic
    def ghci(self, line, cell=None, local_ns=None):
        '''
        Execute code in Ghci, and pull some of the results back into the
        Python namespace.
        '''

        args = parse_argstring(self.ghci, line)

        if cell is None:
            code = ''
        else:
            code = cell

        try:
            text_output = self._ghci.run(code, verbose=args.verbose)
        except (ghci2py.Ghci2PyError) as exception:
            msg = exception.message
            raise GhciMagicError('Ghci could not complete execution: %s' % msg)

        key = 'GhciMagic.Ghci'
        display_data = []

        # Publish text output
        if text_output:
            display_data.append((key, {'text/plain': text_output}))

        for source, data in display_data:
            self._publish_display_data(source, data)


__doc__ = __doc__.format(GHCI_DOC=' '*8 + GhciMagics.ghci.__doc__,
                         GHCI_PUSH_DOC=' '*8 + GhciMagics.ghci_push.__doc__,
                         GHCI_PULL_DOC=' '*8 + GhciMagics.ghci_pull.__doc__)


def load_ipython_extension(ip):
    """Load the extension in IPython and overwrite the normal IPython running
    instance's `run_cell` method with one that invokes the ghci cell magic."""
    ip.register_magics(GhciMagics)

    def new_run_cell(self, raw_cell, **kwds):
        self.run_cell_magic('ghci', '', raw_cell)  # ignore **kwds

    from IPython.core.interactiveshell import InteractiveShell
    func_type = type(InteractiveShell.run_cell)
    ip.run_cell = func_type(new_run_cell, ip, InteractiveShell)
