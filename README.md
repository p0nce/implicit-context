# `implicit-context` 

## What's this?

`implicit-context` is a DUB package implementing an implicit context system for D as a library.

A **context** is a table of named values, and each thread has a TLS stack of hierarchical contexts. It is similar to **namespaces** or **environment variables**, as the top-most name get the lookup.

It is a secondary stack for your program, to be used to pass "contextual" parameters like: 
- Allocators, 
- Loggers, 
- and anything belonging to "context". 

This system is inspired by Odin, Scala, and Jai, but without language support:
- It doesn't change the **ABI**, nor is there a hidden parameter in function calls
- But you need to call `context.push()` and `context.pop()` manually.



## Features
- Set and get **context variables**.
- Namespaced look-up, with masking.
- Hash-based lookup with 64-bit bloom to save on string comparisons.
- Includes basic contextual APIs built upon `implicit-context`:
  * Allocator
  * Logger
  * User Pointer
- **D subset:** `-betterC`-compatible, `@nogc`, `nothrow`
- **Bonus:** Fearless stack allocation.  
  You may allocate on that TLS stack with `context.alloca(size_t size)` to get a temporary buffer.

