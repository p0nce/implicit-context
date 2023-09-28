# `implicit-context` 

## What's this?

`implicit-context` is a DUB package implementing an implicit context system for D as a library.

A **context** is a table of named values, and each thread has a TLS stack of hierarchical contexts. It is similar to **namespaces** or **environment variables**, as the top-most name get the lookup.

It is a secondary stack for your program, to be used to pass "contextual" parameters like: 
- Allocators, 
- Loggers, 
- and anything belonging to "context". 

This system is inspired by Odin, Scala, and Jai, but without language support:
- It doesn't change the **ABI**, nor is there a hidden parameter in function calls.
- But you need to call `context.push()` and `context.pop()` manually, the language will not manage that for you.



## Features
- Set and get **context variables**.
- Namespaced look-up, with masking.
- Hash-based lookup with 64-bit bloom to save on string comparisons.
- Includes basic contextual APIs built upon `implicit-context`:
  * Allocator
  * Logger
  * User Pointer
- **D subset:** `-betterC`-compatible, `@nogc`, `nothrow`.  
  You need TLS and a C runtime though.


## Usage

### Set a context variable
```d
// Create or update myInt to value 8.
context.set!int("myInt", 8); 
```

**Variable names MUST be valid D identifiers**, else it's a programming error.

```d
// Crash. "045" is an invalid identifier.
context.set!int("045", 1); 
```

### Get a context variable

```d
// Retrieve value of myInt. This value is thread-local.
int myInt = context.get!int("myInt");
```

When using `context.get`, an unknown variable identifier is a **programming error** and would crash:
```d
int myInt = context.get!int("__non_Existing__"); // Crash
```

Use `context.query` for an optional variable:

```d
int myInt;
bool found = context.query!int("myInt");
```

_Note: wrong type size will crash. Type mismatch with right size will silently succeed, currently._




### Push and pop context scopes

- `context.push`: Push context, begin a new one.
- `context.pop`: Pop context, restore previous values.

```d
context.set!int("var", 4);

context.push;
context.set!int("var", 5); // mask former context variable
context.pop;

assert(context.get!int("var") == 4);
```

### Using the Context Allocator API

How to allocate and reallocate:
```d
// Allocate 1024 bytes.
void* p = context.allocator.malloc(1024);

// Change the allocation size to 24 bytes.
context.allocator.realloc(p, 24);

// Free the allocation.
context.allocator.free(p);
```