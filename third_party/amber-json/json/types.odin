// Derived from Odin's core:encoding/json at dev-2026-08 (8412dc3), Copyright (c) 2016-2025
// Ginger Bill, under the zlib licence in third_party/odin/LICENSE.
// Altered for amber-json: the default is strict JSON; DEFAULT_MAX_DEPTH; the Trailing_Data and
// Nesting_Too_Deep errors.
// Each change is marked "amber-json:" where it is made.
/*
Encoding and decoding JSON in strict `JSON`, [[ JSON5 ; https://json5.org/ ]] and [[ BitSquid ; https://bitsquid.blogspot.com/2009/10/simplified-json-notation.html ]] variants.

Using one of these `Specification`s. amber-json: the default is JSON, which is the one to read
untrusted input with; the others are read only when asked for.
	JSON
		strict JSON
	JSON5
		pure superset of JSON and valid JavaScript
		https://json5.org/

		* Object keys may be an ECMAScript 5.1 IdentifierName.
		* Objects may have a single trailing comma.
		* Arrays may have a single trailing comma.
		* Strings may be single quoted.
		* Strings may span multiple lines by escaping new line characters.
		* Strings may include character escapes
		* Numbers may be hexadecimal.
		* Numbers may have a leading or trailing decimal point.
		* Numbers may be IEEE 754 positive infinity, negative infinity, and NaN.
		* Numbers may begin with an explicit plus sign.
		* Single and multi-line comments are allowed.
		* Additional white space characters are allowed.

	MJSON
		pure superset of JSON5, may not be valid JavaScript
		https://bitsquid.blogspot.com/2009/10/simplified-json-notation.html

		* All the same features as JSON5 plus extras.
		* Assume an object definition at the root level (no need to surround entire file with { } ).
		* Commas are optional, using comma insertion rules with newlines.
		* Quotes around object keys are optional if the keys are valid identifiers.
		* : can be replaced with =
*/
package json

import "core:strings"

Specification :: enum {
	JSON,
	JSON5, // https://json5.org/
	SJSON, // https://bitsquid.blogspot.com/2009/10/simplified-json-notation.html
	Bitsquid = SJSON,
	MJSON = SJSON,
}




// amber-json: strict JSON (core's was JSON5, so every call that left the spec out read comments,
// single quotes and trailing commas).
DEFAULT_SPECIFICATION :: Specification.JSON

// amber-json: how many objects and arrays may be open at once in a document parse, unmarshal
// and is_valid read; one more is .Nesting_Too_Deep. Each level is a call deeper, and core had
// no limit, so a document of `[` ran out of stack.
DEFAULT_MAX_DEPTH :: 512

Null    :: distinct rawptr
Integer :: i64
Float   :: f64
Boolean :: bool
String  :: string
Array   :: distinct [dynamic]Value
Object  :: distinct map[string]Value

Value :: union {
	Null,
	Integer,
	Float,
	Boolean,
	String,
	Array,
	Object,
}

// amber-json: one value's text, exactly as it was written. Both forms of unmarshal fill a Raw
// field with the bytes of the value at its key, whitespace and escapes included, after the whole
// document has passed parse's rules (so a key given twice inside it is refused like anywhere
// else); marshal writes it back unchanged once it is one valid value of the output's
// specification, and an empty Raw as null, or not at all with omitempty. Go's RawMessage.
Raw :: distinct string

Error :: enum {
	None,

	EOF, // Not necessarily an error

	// Tokenizing Errors
	Illegal_Character,
	Invalid_Number,
	String_Not_Terminated,
	Invalid_String,
	Invalid_Rune,


	// Parsing Errors
	Unexpected_Token,
	Expected_String_For_Object_Key,
	Duplicate_Object_Key,
	Expected_Colon_After_Key,
	Trailing_Data,    // amber-json: something after the value
	Nesting_Too_Deep, // amber-json: past max_depth
	
	// Allocating Errors
	Invalid_Allocator,
	Out_Of_Memory,
}




destroy_value :: proc(value: Value, allocator := context.allocator, loc := #caller_location) {
	context.allocator = allocator
	#partial switch v in value {
	case Object:
		for key, elem in v {
			delete(key, loc=loc)
			destroy_value(elem, loc=loc)
		}
		delete(v, loc=loc)
	case Array:
		for elem in v {
			destroy_value(elem, loc=loc)
		}
		delete(v, loc=loc)
	case String:
		delete(v, loc=loc)
	}
}

@(require_results)
clone_value :: proc(value: Value, allocator := context.allocator) -> Value {
	value := value
	context.allocator = allocator

	#partial switch &v in value {
	case Object:
		new_o := make(Object, len(v))
		for key, elem in v {
			new_o[strings.clone(key)] = clone_value(elem)
		}
		return new_o
	case Array:
		new_a := make(Array, len(v))
		for elem, idx in v {
			new_a[idx] = clone_value(elem)
		}
		return new_a
	case String:
		return strings.clone(v)
	}

	return value
}