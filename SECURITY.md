# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately to the maintainers via a
GitHub security advisory on this repository. Do not open a public issue for
security-sensitive reports.

## Scope

zig-xml is a lenient tokenizer intended to inspect untrusted, possibly hostile
markup. It performs no allocation per event, runs unterminated constructs to
end of input rather than erroring, and never executes or resolves external
entities (there is no DTD processing and no network or file access), so it is
not subject to XML external-entity (XXE) or billion-laughs entity-expansion
attacks. Reports of input that causes a crash, unbounded memory growth, or a
non-terminating loop are in scope.
