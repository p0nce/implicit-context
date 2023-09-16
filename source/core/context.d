/**

This is an implicit context system like in Odin, itself probably inspired by Scala implicits.

"In each scope, there is an implicit value named context. This context variable is local to each 
scope and is implicitly passed by pointer to any procedure call in that scope (if the procedure 
has the Odin calling convention)."

Without language support, we don't have the ABI and the scope-specific context, however with TLS 
and manual scopes we can emulate that to pass parameters in an implicit way (scoped globals, in a way).

Examples:
  - allocators
  - loggers
  - tuning variables in audio plugins
  - the UI "context" in UIs
  - the audio "context" in DSP

Note: internal stack is handled with malloc/realloc/free from the C stdlib.


Example:

     // writeln(context.userStuff); // runtime crash
     context.userStuff = 4;
     assert(context.userStuff == 4);

     void subProc()
     {
        pushContext();

        assert(context.userStuff == 4); // follows chain of contexts
        context.userStuff == 3;
        assert(context.userStuff == 3); // stack-like organization of contexts

        popContext();

        assert(context.userStuff == 4); // stack-like organization of contexts
     }
    subProc();

*/
module core.context;

import core.stdc.stdlib : malloc, free, realloc;

nothrow @nogc @safe:

// Usage: a bit like Odin.
unittest 
{
    void supertramp()
    {
        // this `context` is the same as the parent procedure that it was called from
        assert(context.user_index == 123);

        // From this example, context.user_index == 123
        // A context.allocator is assigned to the return value of `my_custom_allocator()`
    }

    auto c = context; // copy the current scope's context

    context.user_index = 456;
    {
        context.allocator = null;
        context.user_index = 123;
        supertramp(); // the `context` for this scope is implicitly passed to `supertramp`
    }

    // `context` value is local to the scope it is in
    assert(context.user_index == 456);
}

/// Public API of a "context".
struct ImplicitContext // shouldn't be named normally
{
public:
pure nothrow @nogc @safe:


    /// Get a context variable.
    auto opDispatch(string name)()
    {
        U res;        
        return res;
    }

    /// Set (and create) a context variable.
    auto opDispatch(string name, Arg)(Arg arg)
    {
        // TODO
    }

private:

    /// Non-owning pointer to thread-local context stack.
    ContextStack* stack;

    /// Offset of the context position in the context stack.
    /// This way on realloc we don't have to update the offsets of existing contexts.
    size_t offset;
}

/// Return current context object.
/// An `ImplicitContext` is safely copyable, but only the top-most context per-thread can be 
/// modified (like in _the_ stack).
ImplicitContext context()
{
    return g_contextStack.currentContext();
}

/// Saves context on the thread-local context stack. The current `context()` becomes a copy of that.
/// Needs to be paired with `pop`.
/// Returns: the new top context, so that you can set a context value immediately.
ImplicitContext pushContext()
{
    return g_contextStack.pushContext();
}

/// Restore formerly pushed context from thread-local context stack.
void popContext()
{
    g_contextStack.popContext();
}


private:

// All implementation below.

/// A TLS stack, one for each thread.
ContextStack g_contextStack;

/// A thread local implicit stack, one for each threads.
/// Must-be self-initializing. It is arranged a bit like the CPU stack actually.
/// Linear scan across scopes to find a particular identifier.
struct ContextStack
{
nothrow @nogc @safe:
public:

    ImplicitContext currentContext() return
    {
        // TODO: must create a first entry if none yet.
        return ImplicitContext(&this, offsetOfTopContext);
    }

    ImplicitContext pushContext() return
    {
        // push offset of start of parent context
        pushBytes(cast(ubyte*) &offsetOfTopContext, size_t.sizeof);

        // Point to new context.
        offsetOfTopContext = size;
        
        return currentContext();
    }

    void popContext() @trusted
    {
        // Retrieve parent context location.

        const(ubyte)* p = cast(const(ubyte)*) &buffer[offsetOfTopContext - size_t.sizeof];
        size_t parentOffset;
        ubyte* bytes = cast(ubyte*) parentOffset;        
        bytes[0..size_t.sizeof] = p[0..size_t.sizeof];

        // Drop former context content.
        size = offsetOfTopContext;

        // Point to parent context now.
        offsetOfTopContext = parentOffset;
    }


private:

    void* buffer = null; // A single buffer.
    
    // Offset of the start of the current context, in the stack.
    // Stack grows to positie addresses.
    size_t offsetOfTopContext = 0;
    
    // Number bytes in the complete stack.
    size_t size = 0;
    
    // Number of bytes in the allocated buffer.
    size_t capacity = 0;

    /// Push bytes on stack, extend memory if needed.
    void pushBytes(scope const(ubyte)* bytes, size_t sz) @trusted
    {
        if (capacity < size + sz)
        {
            buffer = safe_realloc(buffer, size + sz); // PERF: optimize upsize realloc
            capacity = size + sz;
        }

        ubyte* p = cast(ubyte*) &buffer[size];
        p[0..sz] = bytes[0..sz];
        size += sz;
    }

    // Pop bytes from stack.
    void popBytes(ubyte* bytes, size_t sz) @trusted
    {
        ubyte* p = cast(ubyte*) &buffer[size-sz];
        bytes[0..sz] = p[0..sz];
        size -= sz;

        // TODO: realloc in case we can win a sizeable amount of memory.
    }
}
 

void* safe_realloc(void* ptr, size_t newSize) @trusted
{
    if (newSize == 0)
    {
        free(ptr);
        return null;
    }
    return realloc(ptr, newSize);
}


/** 

    APPENDIX: ABI of context stack.

    Let SZ = size_t.sizeof;


     -SZ offset of parent context.
    0000 number of entries in the context "numEntries"
    0004 bloom filter of identifier hashes
    
    foreach(entry; 0..numEntries x times):
        
        0000        size in bytes, including identifier and this header.
        0004        size of identifier in bytes
        0008        identifier (utf-8 encoding).
        0008+len    size of value in bytes
        0008+len+4  context value

*/
    