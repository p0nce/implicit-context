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
nothrow @nogc @safe:


private:

    /// Non-owning pointer to thread-local context stack.
    ContextStack* stack;

    /// Offset of the context position in the context stack.
    /// This way on realloc we don't have to update the offsets of existing contexts.
    size_t offset;

    /// Push bytes on the stack.
    void pushBytes(const(ubyte)* bytes, size_t size)
    {

    }
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
/// Returns: the new top context.
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

    ImplicitContext currentContext()
    {
        // TODO: must create a first entry if none yet.

        return ImplicitContext(this, 


    }

    ImplicitContext pushContext()
    {


    }


private:
    void* buffer = null; // A single buffer.
    size_t offsetOfTopContext = 0;
    size_t size;
}
 


void* safe_realloc(void* ptr, size_t newSize)
{
    if (newSize == 0)
    {
        free(ptr);
        return null;
    }
    return realloc(ptr, newSize);
}