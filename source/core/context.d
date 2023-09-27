/**

This is an implicit context system like in Odin, itself probably inspired by Scala implicits.
In other words, a system to have scoped globals.

"In each scope, there is an implicit value named context. This CONTEXT VARIABLE is local to each 
scope and is implicitly passed by pointer to any procedure call in that scope (if the procedure 
has the Odin calling convention)."

Without language support, we don't have the ABI and the scope-specific context, however with TLS 
and manual scopes we can emulate that to pass parameters in an implicit way (scoped globals, in a way).

Note: this module uses TLS.

Examples:
  - allocators
  - loggers
  - tuning variables in audio plugins
  - the UI "context" in UIs
  - the audio "context" in DSP

Note: internal stack is handled with malloc/realloc/free from the C stdlib. Performance of internal
      stack relies on a malloc implementation that is itself lockfree, else the realloc could 
      stall other threads from time to time. The context are also not designed to be very large.

Important difference:
    `context.push()` and `context.pop()` are explicit here.
    Leaving a D scope {} doesn't restore parent context (there is no language support), you need 
    to call `push`/`pop` manually. On the plus side, no ABI change are needed and context stack
    is not meant to be touched very frequently.


Example:

    context.set!int("userStuff", 4);
    assert(context.get!int("userStuff") == 4);

    void subProc()
    {
        context.push;

        assert(context.get!int("userStuff") == 4);            // follows chain of contexts

        context.set!int("userStuff", 3);
        assert(context.get!int("userStuff") == 3);            // stack-like organization of contexts

        void* buffer = context.alloca(128);                   // Support stack allocation.

        context.pop;                                         // buffer reclaimed here

        assert(context.get!int("userStuff") == 4);            // stack-like organization of contexts, with hierarchic namespacing
    }
    subProc();

*/
// TODO: error system that propagates on popContext? so as to replace exceptions.
// TODO: what to do for lifetime stuff. A function to be called on release? See also: COM.
// TODO: what about a context destructor? like an at_exit stack. What about a destructor by variable?
// TODO: what to do for GC roots? context might be scanned somehow.
// TODO: should contexts be copyable? Why does Odin do this?
module core.context;

import core.stdc.stdlib : malloc, free, realloc;
import core.stdc.stdio: printf, vsnprintf;
import core.stdc.stdarg: va_start, va_end, va_list;


nothrow @nogc @safe:




public /* <Public Context API> */
{
    /// Return current context object.
    /// An `ImplicitContext` is safely copyable, but only the top-most context per-thread can be 
    /// modified (like in _the_ stack).
    /// There is no reason to store it.
    ImplicitContext context()
    {
        return g_contextStack.currentContext();
    }

    /// A "context" implements per-thread scoped globals. It is a frame in the secundary stack.
    struct ImplicitContext // shouldn't be named normally
    {
    public:
    nothrow @nogc @safe:

        /// Get a context variable. The look-up will chain to above contexts like sort of namespaces 
        /// or a dynamic cast. Topmost context gets the lookup, like namespaces or prototype chains.
        ///
        /// Note: Using the wrong type, or the wrong identifier, is a programming error and will crash.
        ///       Identifiers mask those of earlier scopes.
        ///       Lookup MUST succeed else it's a bug.
        T get(T)(const(char)[] name)
        {
            T res;
            if (query!T(name, res))
                return res;
            else
                assert(false); // no match, program error
        }

        /// Query a context variable (with the possibility that it doesn't exist). The look-up will
        /// chain to above contexts like sort of namespaces or a dynamic cast. Topmost context gets 
        /// the lookup, like namespaces or prototype chains.
        ///
        /// Note: Using a mismatched type size is a programming error and will crash.
        bool query(T)(const(char)[] name, out T res) @trusted
        {
            size_t contextOffset = offset;
            while(contextOffset != 0)
            {
                bool found = getValue(contextOffset, name, cast(ubyte*)(&res), res.sizeof);
                if (found)
                {
                    return true;
                }

                // Jump to parent scope.
                stack.readValue!size_t(contextOffset, contextOffset);
            }
            return false;
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
            hashcode_t hashCode;
            bool found = getValueLocationAndSize(offset, name, existing, varSize, hashCode);
            if (found)
            {
                // modify in place
                if (varSize != T.sizeof)
                    assert(false); // bad size, programming error. Type safety error checked at runtime.

                foreach(n; 0..T.sizeof)
                    existing[n] = pvalue[n];
            }
            else
            {
                stack.pushValue!hashcode_t(hashCode);
                stack.pushValue!size_t(name.length);
                stack.pushValue!size_t(T.sizeof);
                stack.pushBytes(cast(ubyte*) name.ptr, name.length);
                stack.pushBytes(cast(ubyte*) pvalue, T.sizeof);

                // Increment number of entries
                stack.incrementVariableCount();
                stack.updateContextHashCode(hashCode);
            }
        }

        /// Allocates a temporary buffer on the context stack. 
        /// The lifetime of this buffer extends until the `popContext` is called.
        /// Note: This buffer is not scanned, and shouldn't contain GC pointers.
        /// You can't search stack allocation created that way by name.
        void* alloca(size_t size)
        {
            if (stack.offsetOfTopContext != offset)
            {
                // Can't alloca except from top-context.
                assert(false);
            }
            stack.pushValue!hashcode_t(0);   // zero hashcode
            stack.pushValue!size_t(0);
            stack.pushValue!size_t(size);
            void* p = stack.pushBytesUninitialized(size);

            // Increment number of entries
            stack.incrementVariableCount();

            // Note: no need to update bloom, since hash of empty string is zero.

            return p;
        }


        /// Helper for `pushContext()`.
        /// This isn't tied to this particular context, so `static` it is.
        static void push()
        {
            pushContext();
        }

        static void pop()
        {
            popContext();
        }

    private:

        /// Non-owning pointer to thread-local context stack.
        ContextStack* stack;

        /// Offset of the context position in the context stack.
        /// This way on realloc we don't have to update the offsets of existing contexts.
        size_t offset;


        // Find the location of a value and its size in this context.
        bool getValueLocationAndSize(size_t contextOffset, 
                                     scope const(char)[] name,
                                     ref ubyte* location, 
                                     out size_t varSize,
                                     out hashcode_t outHashCode) @trusted
        {
            // Compute hash of identifier
            hashcode_t hashCode;
            bool validName = validateContextIdentifier(name, hashCode);
            if (!validName) 
            {
                // If you fail here, it is because the identifier searched for is not a valid 
                // Context identifier. This is a programming error to use such a name.
                // Only strings that would be valid D identifier can go into an implicit context as variable name.
                assert(false);
            }

            outHashCode = hashCode;

            size_t entries;
            stack.readValue(contextOffset + size_t.sizeof, entries);

            hashcode_t hashUnion;
            stack.readValue(contextOffset + size_t.sizeof * 2, hashUnion);
            if ( (hashUnion & hashCode) != hashCode)
            {
                // If the name was in this context, then it would be in the hash union. (aka a bloom filter).
                // Report not found.
                // Stack allocation (empty string and 0 hashcode) cannot be searched for, so it's not an issue.
                return false;
            }

            size_t varHeader = contextOffset + CONTEXT_HEADER_SIZE; // skip context header

            for (size_t n = 0; n < entries; ++n)
            {
                hashcode_t hashHere;
                size_t identSize, valueSize;
                stack.readValue(varHeader, hashHere);
                stack.readValue(varHeader + HASHCODE_BYTES, identSize);
                stack.readValue(varHeader + HASHCODE_BYTES + size_t.sizeof, valueSize);

                if (hashHere == hashCode) // Same hashcode? Compare the identifier then.
                {
                    const(char)[] storedIndent = cast(const(char)[]) stack.bufferSlice(varHeader + HASHCODE_BYTES + size_t.sizeof * 2, identSize);
                    if (storedIndent == name)
                    {
                        varSize = valueSize;
                        location = cast(ubyte*)(&stack.buffer[varHeader + HASHCODE_BYTES + size_t.sizeof * 2 + identSize]);
                        return true;
                    }
                }

                varHeader = varHeader + HASHCODE_BYTES + size_t.sizeof * 2 + identSize + valueSize;
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
            hashcode_t hashCode;
            if (getValueLocationAndSize(contextOffset, name, location, varSize, hashCode))
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

} /* </Public Context API> */



unittest /* <Usage Example> */
{

    void supertramp()
    {
        // this `context` is the same as the parent procedure that it was called from
        assert(context.get!int("user_index") == 123);

        context.push;
        context.set!int("user_index", 64); // could use that one, or just `context`.
        context.pop;
    }

    context.set!int("user_index", 456);

    // Allocate on TLS stack.
    () @trusted
    {
        ubyte* storage = cast(ubyte*) context.alloca(128);
        storage[0..128] = 2;
    }();


    assert(context.get!int("user_index") == 456);

    {
        context.set!(void*)("allocator", null);
        context.push;
        context.set!int("user_index", 123);

        // The `context` for this scope is implicitly passed to `supertramp`, as it's in a TLS stack, there is no ABI change or anything to do.
        // but you don't get implicit context push/pop.
        supertramp(); 

        assert(context.get!int("user_index") == 123);
        context.pop;
    }

    // `context` value is local to the scope it is in
    assert(context.get!int("user_index") == 456);

} /* </Usage Example> */





private /* <Implementation of context stack> */
{
    alias hashcode_t = uint;

    /// Size in bytes of an identifier hashCode.
    enum size_t HASHCODE_BYTES = hashcode_t.sizeof;

    enum size_t CONTEXT_HEADER_SIZE = HASHCODE_BYTES + 2 * size_t.sizeof; 

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
            hashcode_t hashUnion = 0; // nothing yet

            // Write frame header.
            pushValue(parentContextLocation);
            pushValue(entries);
            pushValue(hashUnion);
        
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
            hashcode_t hashUnion = 0;
            pushValue(offset); // 0 location is null context, should not be accessed.

            pushValue(offset);
            pushValue(entries);
            pushValue(hashUnion);
            offsetOfTopContext = offsetOfRootContext;
            contextCount = 1;

            // Populate with default implementations of allocator.
            populateContextWithDefaultUserPointer(context);
            populateContextWithDefaultAllocator(context);
            populateContextWithDefaultLogger(context);

            dumpStack(context.stack);
        }

        void incrementVariableCount() @trusted
        {
            size_t* numValues = cast(size_t*)(&buffer[offsetOfTopContext + size_t.sizeof]);
            *numValues = *numValues + 1;
        }

        void updateContextHashCode(hashcode_t hashCode) @trusted
        {
            hashcode_t* hashUnion = cast(hashcode_t*)(&buffer[offsetOfTopContext + size_t.sizeof*2]);
            *hashUnion |= hashCode;
        }

        const(ubyte[]) bufferSlice(size_t offset, size_t len) return @trusted
        {
            return cast(ubyte[])buffer[offset..offset+len];
        }

        void ensureCapacity(size_t sizeBytes) @trusted
        {
            if (capacity < sizeBytes)
            {
                size_t newCapacity = calculateGrowth(sizeBytes, capacity);
                buffer = safe_realloc(buffer, newCapacity);
                capacity = newCapacity;
            }
        }

        /// Append byte storage at the end (uninitialized), extend memory if needed. Return pointer to allocated area.
        void* pushBytesUninitialized(size_t sz) @trusted
        {
            ensureCapacity(size + sz);
            void* p = &buffer[size];
            size += sz;
            return p;        
        }

        /// Push bytes on stack, extend memory if needed.
        void pushBytes(scope const(ubyte)* bytes, size_t sz) @trusted
        {
            ensureCapacity(size + sz);      

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
            const(T)* p = cast(const(T)*) &buffer[location];
            value = *p;
        }

        // Pop bytes from stack.
        void popBytes(ubyte* bytes, size_t sz) @trusted
        {
            readBytes(size - sz, bytes, sz);
            size -= sz;

            // Note: this never resizes down, like std::vector. TODO add a shrink_to_fit function?
        }
    }

    size_t calculateGrowth(size_t newSize, size_t oldCapacity) pure
    {
        size_t geometric = oldCapacity + oldCapacity / 2;
        if (geometric < newSize) 
            return newSize; // geometric growth would be insufficient
        return geometric;
    }

    // Validate identifier and compute hash at the same time.
    // It's like D identifiers:
    // "Identifiers start with a letter, _, or universal alpha, and are followed by any number of 
    // letters, _, digits, or universal alphas. Universal alphas are as defined in ISO/IEC 
    // 9899:1999(E) Appendix D of the C99 Standard. Identifiers can be arbitrarily long, and are 
    // case sensitive.
    static bool validateContextIdentifier(const(char)[] identifier, ref hashcode_t hashCode) pure nothrow @nogc @safe 
    {
        if (identifier.length == 0)
        {
            hashCode = 0;
            return true; // empty string is a valid identifier (alloca allocations on the context stack).
        }

        static bool isDigit(char ch)
        {
            return ch >= '0' && ch <= '9';
        }
        static bool isAlpha(char ch)
        {
            return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch == '_');
        }

        char ch = identifier[0];
        hashcode_t hash = ch;

        if (!isAlpha(ch)) // first character must be an alpha
            return false;
        
        for(size_t n = 1; n < identifier.length; ++n)
        {
            ch = identifier[n];
            if (!isAlpha(ch) && !isDigit(ch))
                return false;
            hash = hash * 31 + ch;
        }
        hashCode = hash;
        return true;
    }
    unittest
    {
        hashcode_t hash = 2;
        assert(validateContextIdentifier("", hash));
        assert(hash == 0); // hash of empty string is zero

        assert(validateContextIdentifier("__allocator", hash));
        assert(!validateContextIdentifier("é", hash)); // invalid identifier       
    }

    debug = debugContext;


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
                hashcode_t hashUnion;
                stack.readValue(ofs, parentContextOfs);
                stack.readValue(ofs + size_t.sizeof, entries);
                stack.readValue(ofs + size_t.sizeof*2, hashUnion);

                printf(" - parent       = %zu\n", parentContextOfs);
                printf(" - entries      = %zu\n", entries);
                printf(" - hash union   = %x\n", hashUnion);

                ofs += CONTEXT_HEADER_SIZE;

                for (size_t n = 0; n < entries; ++n)
                {
                    hashcode_t hashCode;
                    size_t identLen;
                    size_t varLen;
                    stack.readValue(ofs,                                   hashCode);
                    stack.readValue(ofs + HASHCODE_BYTES ,                 identLen);
                    stack.readValue(ofs + HASHCODE_BYTES  + size_t.sizeof, varLen);

                    printf(" - context variable %zu:\n", n);

                    const(ubyte)[] ident = stack.bufferSlice(ofs + HASHCODE_BYTES + size_t.sizeof * 2, identLen);
                    const(ubyte)[] data = stack.bufferSlice(ofs + HASHCODE_BYTES + size_t.sizeof * 2 + identLen, varLen);
                    printf("    * hash       = %x\n", hashCode);
                    printf(`    * identifier = "%.*s"` ~ " (%zu bytes)\n", cast(int)(ident.length), ident.ptr, ident.length);
                    printf(`    * content    = `);
                    for (size_t b = 0; b < data.length; ++b)
                    {
                        printf("%02X ", data[b]);
                    }
                    printf(" (%zu bytes)\n", varLen);
                    ofs += HASHCODE_BYTES + size_t.sizeof * 2 + identLen + varLen;
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
      APPENDIX: ABI of context stack implemented above.

      Let SZ = size_t.sizeof;
      Let HZ = hashcode_t.sizeof;


      0000            parent         Offset of parent context in the stack (root context is at 
                                     location SZ, null context at location 0)
      SZ              numEntries     Number of entries in the context "numEntries"
      SZ*2            hashUnion      Bloom filter of identifier hashes (union of hashes), this allows
                                     to skip whole context while searching for a key.  (HZ bytes)

      foreach(entry; 0..numEntries x times):
        0000             hashCode     Hash code of following identifier (HZ bytes).
          HZ             identLen     Size of identifier in bytes.
                                      0 is a special value for `alloca()` allocation. Such context 
                                      variables have no names.
        HZ+SZ            valueLen     Size of value in bytes.
        HZ+2*SZ          name         Identifier string (char[]).
        HZ+2*SZ+identlen value        Variable value.

    */
}  /* </Implementation of context stack> */



// This file could have ended here, but here is some example of API usage, to give some ideas and 
// also implement the basics.
//
// The idea of having allocators and such in this library is so that a package that depends on a 
// package that itseld depends on "implicit-context" will not be forced to use "implicit-context" 
// (unless there is some customization to do).



//
// 1. <CONTEXT USER POINTER API>
//
// The simplest API just holds a void* "user pointer", like many C APIs do. 
// This can avoid a bit of trampoline callbacks.
// This context variable shouldn't THAT useful in general, since you could as well use the
// implicit-context system now. It is there to clean-up the call stack of things that might 
// use user pointers extensively.
public  
{
    /// UFCS Getter for user pointer.
    void* userPointer(ImplicitContext ctx)
    {
        return ctx.get!(void*)(CONTEXT_USER_POINTER_IDENTIFIER);
    }

    /// UFCS Setter for user pointer.
    void userPointer(ImplicitContext ctx, void* userData)
    {
        ctx.set!(void*)(CONTEXT_USER_POINTER_IDENTIFIER, userData);
    }
}
private
{
    static immutable CONTEXT_USER_POINTER_IDENTIFIER = "__userPointer";

    void populateContextWithDefaultUserPointer(ImplicitContext ctx)
    {
        ctx.set!(void*)(CONTEXT_USER_POINTER_IDENTIFIER, null); // default is simply a null pointer
    }
}
@trusted unittest
{
    struct Blob
    {
    }
    Blob B;
    context.userPointer = &B;
    assert(context.userPointer == &B);
}
// 1. </CONTEXT USER POINTER API>



//
// 2. <CONTEXT ALLOCATOR API>
//
// Minimal allocator API.
// Like in STB libraries, this allows to pass a custom `realloc` function, and that one is 
// sufficient to customize most things.
public
{
    /// UFCS Getter for context allocator.
    ContextAllocator allocator(ImplicitContext ctx)
    {
        return ctx.get!ContextAllocator(CONTEXT_ALLOCATOR_IDENTIFIER);
    }

    /// UFCS Setter for context allocator.
    void allocator(ImplicitContext ctx, ContextAllocator allocator)
    {
        ctx.set!ContextAllocator(CONTEXT_ALLOCATOR_IDENTIFIER, allocator);
    }

    // Context allocator.
    extern(C) @system nothrow @nogc
    {
        /// This is not _exactly_ the same as C's realloc function!
        ///
        /// Params:
        /// p  This is the pointer to a memory block previously allocated with the `realloc_fun_t`.
        ///    If this is `null`, a new block is allocated and a pointer to it is returned by the 
        ///    function.
        ///
        /// size This is the new size for the memory block, in bytes. If it is 0 and `ptr` points 
        /// to an existing block of memory, the memory block pointed by ptr is deallocated and a 
        /// `null` pointer is returned.
        /// 
        /// Returns: Pointer to allocated space.
        ///          This can return either `null` or     
        ///
        /// Basically this can implement regular C's `malloc`, `free` and `realloc`, but is not 
        /// completely identical to C's realloc (see `safe_realloc` to see why).
        alias realloc_fun_t = void* function(void* p, size_t size);
    }

    struct ContextAllocator
    {
    nothrow @nogc @safe:

        /// A single function pointer for this allocator API.
        realloc_fun_t realloc; // not owned, this function pointer must outlive the allocator.

        // MAYDO: Could have a few more operations there maybe for convenience.

        /// Allocate bytes, helper function.
        /// Returns: an allocation that MUST be freed with either `ContextAllocator.free` or 
        /// `ContextAllocator.realloc(p, 0)`, even when asking zero size.
        void* malloc(size_t sizeInBytes) @system
        {
            return realloc(null, sizeInBytes);
        }

        /// Deallocate bytes, helper function. `p` can be `null`.
        void free(void* p) @system
        {
            realloc(p, 0);
        }
    }
}
private
{
    static immutable CONTEXT_ALLOCATOR_IDENTIFIER = "__allocator";

    void populateContextWithDefaultAllocator(ImplicitContext ctx)
    {
        ContextAllocator defaultAllocator;
        defaultAllocator.realloc = &safe_realloc;
        ctx.set!ContextAllocator(CONTEXT_ALLOCATOR_IDENTIFIER, defaultAllocator);
    }
    /// A "fixed" realloc that supports the C++23 restrictions when newSize is zero.
    /// This is often useful, so it may end up in public API?
    extern(C) void* safe_realloc(void* ptr, size_t newSize) @system
    {
        if (newSize == 0)
        {
            free(ptr);
            return null;
        }
        return realloc(ptr, newSize);
    }   
}
@system unittest 
{
    void* p = context.allocator.malloc(1024);
    context.allocator.realloc(p, 24);
    context.allocator.free(p);
}
// 2. </CONTEXT ALLOCATOR API>


//
// 3. <CONTEXT LOGGING API>
//
// Minimal logging API.
public
{
    nothrow @nogc @system
    {
        /// This functions prints a format-less, ZERO-TERMINATED string. Hence, the @system interface.
        /// Also, cannot fail.
        alias print_fun_t = void function(const(char)* message);
    }

    struct ContextLogger
    {
    nothrow @nogc @system:
        print_fun_t print; // not owned, this function pointer must outlive the logger.

        extern (C) void printf(const(char)* fmt, ...)
        {
            enum MAX_MESSAGE = 256; // cropped above that

            char[MAX_MESSAGE] buffer;
            va_list args;
            va_start (args, fmt);
            vsnprintf (buffer.ptr, MAX_MESSAGE, fmt, args);
            va_end (args);

            print(buffer.ptr);
        }
    }

    /// UFCS Getter for context allocator.
    ContextLogger logger(ImplicitContext ctx)
    {
        return ctx.get!ContextLogger(CONTEXT_LOGGER_IDENTIFIER);
    }

    /// UFCS Setter for context allocator.
    void logger(ImplicitContext ctx, ContextLogger allocator)
    {
        ctx.set!ContextLogger(CONTEXT_LOGGER_IDENTIFIER, allocator);
    }
}
private
{
    static immutable CONTEXT_LOGGER_IDENTIFIER = "__logger";

    void populateContextWithDefaultLogger(ImplicitContext ctx) @trusted
    {
        ContextLogger defaultLogger;
        defaultLogger.print = &stdc_print;
        ctx.set!ContextLogger(CONTEXT_LOGGER_IDENTIFIER, defaultLogger);
    }

    void stdc_print(const(char)* message) @system
    {
        printf("%s", message);
    }
}
@system unittest
{
    // Note: Format string follow the `printf` specifiers, not the `writeln` specifiers.
    // Yup, don't forget to \n.
    context.logger.printf("Context Logger API: Hello %s\n".ptr, "world.".ptr); 
}
// 3. <:CONTEXT LOGGING API>
