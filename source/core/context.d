/**

This is an implicit context system like in Odin, itself probably inspired by Scala implicits.
In other words, a system to have scoped globals.

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

Important difference:
    `pushContext()` and `popContext()` are explicit here.
    Leaving a scope {} doesn't restore parent context. 


Example:

     // writeln(context.userStuff); // runtime crash
     context.set!int("userStuff", 4);
     assert(context.get!int("userStuff") == 4);

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
// TODO: error system that propagates on popContext?
// TODO: what to do for lifetime stuff. A function to be called on release? See also: COM.
// TODO: what to do for GC roots? context should be scanned somehow.
module core.context;

import core.stdc.stdlib : malloc, free, realloc;

nothrow @nogc @safe:

// Usage: a bit like Odin.
unittest 
{
    void supertramp()
    {
        // this `context` is the same as the parent procedure that it was called from
        assert(context.get!int("user_index") == 123);

        auto ctx = scopedContext(); // save/restore context at end of scope
        ctx.set!int("user_index", 64); // could use that one, or just `context`.
    }

    context.set!int("user_index", 456);

    assert(context.get!int("user_index") == 456);

    {
        pushContext();

        context.set!(void*)("allocator", null);
        pushContext();
        context.set!int("user_index", 123);
        supertramp(); // the `context` for this scope is implicitly passed to `supertramp`, as it's in a TLS stack.
        assert(context.get!int("user_index") == 123);
        popContext();
        popContext();
    }

    // `context` value is local to the scope it is in
    assert(context.get!int("user_index") == 456);
}


/// Public API of a "context".
struct ImplicitContext // shouldn't be named normally
{
public:
nothrow @nogc @safe:

    /// Maximum length of identifier accepted in this API.
    enum maxIdentifierLength = 255;


    /// Get a context variable. The look-up will chain to above contexts like sort of namespaces 
    /// or a dynamic cast. Topmost context gets the lookup.
    ///
    /// Note: Using the wrong type, or the wrong identifier, is a programming error and will crash.
    ///       Identifiers mask those of earlier scopes.
    ///       Lookup MUST succeed else it's a bug.
    T get(T)(const(char)[] name) @trusted
    {
        T res;
        size_t contextOffset = offset;

        while(contextOffset != 0)
        {
            bool found = getValue(contextOffset, name, cast(ubyte*)(&res), res.sizeof);
            if (found)
            {
                return res;
            }

            // Jump to parent scope.
            stack.readValue!size_t(contextOffset, contextOffset);
        }

        assert(false); // no match, program error
    }

    /// Set a context variable. 
    ///
    /// Note: if the variable already exist in this context, it is modified.
    ///       But its size cannot change in this way, without a crash.
    ///       The context where you create a variable MUST be the topmost one, else it's a crash.
    void set(T)(const(char)[] name, T value) @trusted
    {
        if (stack.offsetOfTopContext != offset)
        {
            // Can't set variable except in top context.
            assert(false);
        }

        const(ubyte)* pvalue = cast(const(ubyte)*)&value;

        // First check if it already exists.
        ubyte* existing;
        size_t varSize;
        bool found = getValueLocationAndSize(offset, name, existing, varSize);
        if (found)
        {
            // modify in place
            if (varSize != T.sizeof)
                assert(false); // bad size, programming error
            foreach(n; 0..T.sizeof)
                existing[n] = pvalue[n];
        }
        else
        {
            import core.stdc.stdio;

            stack.pushValue!size_t(name.length); // TODO: in ABI, put size_t here
            stack.pushValue!size_t(T.sizeof);
            stack.pushBytes(cast(ubyte*) name.ptr, name.length);
            stack.pushBytes(cast(ubyte*) pvalue, T.sizeof);

            // Increment number of entries
            stack.incrementVariableCount();
        }
    }    

private:

    /// Non-owning pointer to thread-local context stack.
    ContextStack* stack;

    /// Offset of the context position in the context stack.
    /// This way on realloc we don't have to update the offsets of existing contexts.
    size_t offset;


    // Find the location of a value and its size in this context.
    bool getValueLocationAndSize(size_t contextOffset, 
                                 const(char)[] name,
                                 ref ubyte* location, 
                                 out size_t varSize) @trusted
    {
        size_t entries;
        stack.readValue(contextOffset + size_t.sizeof, entries);

        // PERF: skip the whole context traversal based upon a bloom hash of identifiers there.

        size_t varHeader = contextOffset + 3 * size_t.sizeof; // skip context header
        for (size_t n = 0; n < entries; ++n)
        {
            size_t identSize, valueSize;
            stack.readValue(varHeader, identSize);
            stack.readValue(varHeader+size_t.sizeof, valueSize);

            const(char)[] storedIndent = cast(const(char)[]) stack.bufferSlice(varHeader + size_t.sizeof * 2, identSize);
            if (storedIndent == name)
            {
                varSize = valueSize;
                location = cast(ubyte*)(&stack.buffer[varHeader + size_t.sizeof * 2 + identSize]);
                return true;
            }

            varHeader = varHeader + size_t.sizeof * 2 + identSize + valueSize;
        }
        return false;
    }

    // Find a value in this context.
    bool getValue(size_t contextOffset, 
                  const(char)[] name,
                  ubyte* res, size_t size) @trusted
    {
        size_t varSize;
        ubyte* location;
        if (getValueLocationAndSize(contextOffset, name, location, varSize))
        {
            if (size == varSize)
            {
                foreach(n; 0..size)
                    res[n] = location[n];
                return true;
            }
            else
            {
                assert(false); // bad size
            }
        }
        else
            return false;
    }
}




/// Return current context object.
/// An `ImplicitContext` is safely copyable, but only the top-most context per-thread can be 
/// modified (like in _the_ stack).
ImplicitContext context()
{
    return g_contextStack.currentContext();
}

// Same as ImplicitContext, but RAII.
struct ScopedContext
{
public:
nothrow @nogc @safe:

    ~this()
    {
        popContext();
    }

    alias ctx this;


    @disable this(this);

    ImplicitContext ctx;
}

ScopedContext scopedContext()
{
    pushContext();
    ScopedContext r;
    r.ctx = context();
    return r;
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
        if (contextCount == 0)
            createRootContext();

        return ImplicitContext(&this, offsetOfTopContext);
    }

    ImplicitContext pushContext() return
    {
        if (contextCount == 0)
            createRootContext();

        size_t parentContextLocation = offsetOfTopContext;

        // Point to new context.
        offsetOfTopContext = size;

        // Create number of entries and bloom field.
        size_t entries = 0;
        size_t bloom = 0;

        // Write frame header.
        pushValue(parentContextLocation);
        pushValue(entries);
        pushValue(bloom);
        
        contextCount += 1;

        return currentContext();
    }

    void popContext() @trusted
    {
        // Retrieve parent context location.

        size_t parentLoc;
        readValue(offsetOfTopContext, parentLoc);

        // Drop former context content.
        size = offsetOfTopContext;

        // Point to parent context now.
        offsetOfTopContext = parentLoc;

        contextCount -= 1;
    }


private:

    // A single buffer for all scopes/contexts, singly-linked frames like "the" stack.
    void* buffer = null; 
    
    // Offset of the start of the current context, in the stack.
    // Stack grows to positie addresses.
    size_t offsetOfTopContext = 0;
    
    // Number bytes in the complete stack.
    size_t size = 0;
    
    // Number of bytes in the allocated buffer.
    size_t capacity = 0;

    // Number of contexts.
    size_t contextCount = 0;

    enum size_t offsetOfRootContext = size_t.sizeof;

    void createRootContext()
    {
        assert(contextCount == 0);

        size_t offset = 0; // null context = no parent
        size_t entries = 0;
        size_t bloom = 0;
        pushValue(offset); // 0 location is null context, should not be accessed.

        pushValue(offset);
        pushValue(entries);
        pushValue(bloom);
        offsetOfTopContext = offsetOfRootContext;
        contextCount = 1;
    }

    void incrementVariableCount() @trusted
    {
        size_t* numValues = cast(size_t*)(&buffer[offsetOfTopContext + size_t.sizeof]);
        *numValues = *numValues + 1;
    }

    const(ubyte[]) bufferSlice(size_t offset, size_t len) return @trusted
    {
        return cast(ubyte[])buffer[offset..offset+len];
    }

    /// Push bytes on stack, extend memory if needed.
    void pushBytes(scope const(ubyte)* bytes, size_t sz) @trusted
    {
        if (capacity < size + sz)
        {
            buffer = safe_realloc(buffer, size + sz); // PERF: optimize upsize realloc
            capacity = size + sz;
        }

        ubyte* p = cast(ubyte*) &buffer[size];
        foreach(n; 0..sz)
            p[n] = bytes[n];

        size += sz;
    }

    ///ditto
    void pushValue(T)(T value) @trusted
    {
        pushBytes(cast(ubyte*) &value, value.sizeof);
    }

    // Read bytes from stack. Crash on failure.
    void readBytes(size_t location, ubyte* bytes, size_t sz) @trusted
    {
        ubyte* p = cast(ubyte*) &buffer[location];
        foreach(n; 0..sz)
            bytes[n] = p[n];
    }

    //ditto
    void readValue(T)(size_t location, out T value) @trusted
    {
        const(ubyte)* p = cast(const(ubyte)*) &buffer[location];
        ubyte* bytes = cast(ubyte*) &value;
        foreach(n; 0..T.sizeof)
            bytes[n] = p[n];
    }

    // Pop bytes from stack.
    void popBytes(ubyte* bytes, size_t sz) @trusted
    {
        readBytes(size - sz, bytes, sz);
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

//debug = debugContext;


debug(debugContext)
{
    import core.stdc.stdio;

    void dumpStack(ContextStack* stack) @trusted
    {
        printf("\n\n");
        size_t ofs = ContextStack.offsetOfRootContext;
        while(true)
        {
            printf("*** Context at %zu\n", ofs);
            size_t parentContextOfs;
            size_t entries;
            size_t bloom;
            stack.readValue(ofs, parentContextOfs);
            stack.readValue(ofs + size_t.sizeof, entries);
            stack.readValue(ofs + size_t.sizeof*2, bloom);
            assert(bloom == 0);

            printf(" - parent  = %zu\n", parentContextOfs);
            printf(" - entries = %zu\n", entries);
            printf(" - bloom   = %zu\n", bloom);

            ofs += size_t.sizeof * 3;
            for (size_t n = 0; n < entries; ++n)
            {
                size_t identLen;
                size_t varLen;
                stack.readValue(ofs,                 identLen);
                stack.readValue(ofs + size_t.sizeof, varLen);

                printf(" - context variable %zu:\n", n);

                const(ubyte)[] ident = stack.bufferSlice(ofs + size_t.sizeof * 2, identLen);
                const(ubyte)[] data = stack.bufferSlice(ofs + size_t.sizeof * 2 + identLen, varLen);
                printf(`    * identifier = "%.*s"` ~ " (%zu bytes)\n", cast(int)(ident.length), ident.ptr, ident.length);
                printf(`    * content    = `);
                for (size_t b = 0; b < data.length; ++b)
                {
                    printf("%02X ", data[b]);
                }
                printf(" (%zu bytes)\n", varLen);
                ofs += size_t.sizeof * 2 + identLen + varLen;
            }
            if (ofs == stack.size)
                break;
            assert(ofs < stack.size); // Else, structure broken
            printf("\n");
        }
        printf("\n");
    }
}


/** 

    APPENDIX: ABI of context stack.

    Let SZ = size_t.sizeof;


    0000   offset of parent context in the stack (root context is at location SZ, null context at location 0)
    SZ     number of entries in the context "numEntries"
    SZ*2   bloom filter of identifier hashes (unused yet)
    
    foreach(entry; 0..numEntries x times):
        0000           size of identifier in bytes
        SZ             size of value in bytes 
        2*SZ           identifier (char[])
        2*SZ+identlen  variable value

*/
