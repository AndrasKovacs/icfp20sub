## fcif

Implementation of the elaborator in the draft paper "Elaboration with
First-Class Implicit Function Types" by András Kovács.

We also have here a small supplementary Agda file,
[TelescopeDerivation.agda](TelescopeDerivation.agda), which contains a derivation
of telescopes and curried functions from Section 4 of the paper.

#### Installation

- Install Haskell Stack: https://docs.haskellstack.org/en/stable/README/. I have built this package using stack 2.3.1.
- `stack install` from this directory
- This copies the executable `fcif` to `~/.local/bin`.
- Agda installation for checking the Agda file: see [Agda
  docs](https://agda.readthedocs.io/en/v2.6.0.1/getting-started/installation.html). A
  [standard library](https://github.com/agda/agda-stdlib) is also required.

#### Usage

The executable `fcif` reads an expression from standard input.

- `fcif elab` prints elaboration output.
- `fcif nf` prints the normal form of the input.
- `fcif type` prints the type of the input.

See [benchmarks.fcif](benchmarks.fcif) here for an example.

#### Unicode

We support both unicode and ASCII characters: lambdas can be written as `\` or
`λ` and function arrows as `->` or `→`.

If you already have Agda installed with emacs mode, it is possible to use its
unicode input mode in any buffer by `M-x` `set-input-method`, then `Agda`.

#### Comparison to the paper

Extra features:
- Optional type annotations on lambdas, e.g. `λ (A : U). A`.
- Optional omission of type annotation on implicit binders and let,
   e.g. `let foo = U in foo` and `{A} → A → A`.
- Special treatment of top-level lambdas for the purpose of printing. These
  usually serve as a way of postulating constants. We don't print
  top-lambda-bound variables in meta spines in elaboration output and error
  messages, as they are irrelevant to meta solutions and would only add clutter.

Differences:
- The metacontext is unordered in the implementation, unlike in the
  specification, where it is ordered. In principle, the metacontext as
  implemented can be ordered because the strengthening/occurs checking ensures
  that no cyclic dependencies are present in meta solutions and types.  This is
  a standard implementation strategy, also used e.g. in Agda.

Notation:
- Metavariables are printed as `?n`, where `n` is an integer, meaning
  the `n`-th fresh metavariable.
- Sometimes no name is available for a variable from the surface syntax. In this
  case, the variable is printed as `@n` where `n` is a de Bruijn index. For example,
  in `let foo : U = U → _`, because the non-dependent function is just a shorthand for
  a pi type, the codomain metavariable depends on the unnamed `U` domain, which is printed
  as a de Bruijn index. It would be an optimization
  to treat non-dependent functions specially in elaboration, so that no such dependencies are introduced.
- Inserted binders which arise from curried function insertion are named `Γn`,
  where `n` is an integer. `n` isn't particularly informative, it comes from a
  combination of fresh meta ids and telescope refining.
- We print curried function types the same way as implicit function types. They can be
  disambiguated visually by having a telescope domain.
- Curried lambdas are printed as `λ{x : a}. t` where `a` is a telescope.
- Curried applications are printed as `t {u : a}`, where `a` is a telescope.
