% **SawScript**
% Galois, Inc. | 421 SW 6th Avenue, Suite 300 | Portland, OR 97204

\newpage

Introduction
============

The SAWScript language is a special-purpose programming language
developed by Galois to help orchestrate and track the results of the
large collection of proof tools necessary for analysis and
verification of complex software artifacts.

The language adopts the functional paradigm, and largely follows the
structure of many other functional languages, with some special
features specifically targeted at the coordination of verification
tasks.

This tutorial introduces the details of the language by walking
through several examples, and showing how simple verification tasks
can be described.

Example: Find First Set
=======================

As a first example, we consider a simple function that identifies the
first ``1`` bit in a word. The function takes an integer as input,
treated as a vector of bits, and returns another integer which
indicates the index of the first bit set. This function exists in a
number of standard C libraries, and can be implemented in several
ways.

Reference Implementation
-------------------------

One simple implementation take the form of a loop in which the index
starts out at zero, and we keep track of a mask initialized to have
the least signficant bit set. On each iteration, we increment the
index, and shift the mask to the left. Then we can use a bitwise "and"
operation to test the bit at the index indicated by the index
variable. The following C code uses this approach.

``` {.c}
$include 1-9 code/ffs.c
```

This implementation is relatively straightforward, and a proficient C
programmer would probably have little difficulty believing its
correctness. However, the number of branches taken during execution
could be as many as 32, depending on the input value. It's possible to
implement the same algorithm with significantly fewer branches, and no
backward branches.

Optimized Implementation
------------------------

An alternative implementation, taken by the following program, treats
the bits of the input word in chunks, allowing sequences of zero bits
to be skipped over more quickly.

``` {.c}
$include 11-18 code/ffs.c
```

However, this code is much less obvious than the previous
implementation. If it is correct, we would like to use it, since it
has the potential to be faster. But how do we gain confidence that it
calculates the same results as the original program?

SAWScript allows us to state this problem concisely, and to quickly
and automatically prove the equivalence of these two functions for all
possible inputs.

Generating LLVM Code
--------------------

The SAWScript interpreter knows how to analyze LLVM code, but most
programs are originally written in a higher-level language such as C,
as in our example. Therefore, the C code must be translated to LLVM,
using something like the following command:

```
$cmd clang -c -emit-llvm -o code/ffs.bc code/ffs.c
```

Equivalence Proof
-----------------

```
$include all code/ffs_llvm.saw
```

Cross-Language Proofs
---------------------

We can implement the FFS algorithm in Java with code almost identical
to the C version.

The reference version uses a loop, like the C version:

``` {.java}
$include 2-10 code/FFS.java
```

And the efficient implementation uses a fixed sequence of masking and
shifting operations:

``` {.java}
$include 12-19 code/FFS.java
```

Although in this case we can look at the C and Java code and see that
they perform almost identical operations, the low-level operators
available in C and Java do differ somewhat. Therefore, it would be
nice to be able to gain confidence that they do, indeed, perform the
same operation.

We can do this with a process very similar to that used to compare the
reference and implementation versions of the algorithm in a single
language.

First, we compile the Java code to a JVM class file.

```
$cmd javac -g code/FFS.java
```

Now we can do the proof both within and across languages:

```
$include all code/ffs_compare.saw
```

Future Enhancements
===================

Improved Symbolic Simulation Control
------------------------------------

  * More sophisticated control over the symbolic simulation process,
    allowing a wider range of functions from imperative languages to
    be translated into formal models.
  * Support for compositional verification.

Improved Integration with External Proof Tools
----------------------------------------------

  * More complete SMT-Lib export support.
  * Support for automatic invocation of SMT solvers and interpretation
    of their output.
  * Support for generation of (Q)DIMACS CNF and QBF files, for use
    with SAT and QBF solvers.
  * Support for automatic invocation of SAT and QBF solvers, and
    interpretation of their output.

Improved Support for Manipulating Formal Models
-----------------------------------------------

  * Specifying and applying rewrite rules to simplify formal models.
  * Applying formal models directly to concrete arguments.
  * Applying formal models automatically to a large collection of
    randomly-generated concrete arguments.

Summary
=======

TODO