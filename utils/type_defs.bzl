# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

"""Provides macros for queries type information."""

_SELECT_TYPE = type(select({"DEFAULT": []}))

def is_select(thing):
    return type(thing) == _SELECT_TYPE

def is_unicode(arg):
    """Checks if provided instance has a unicode type.

    Args:
      arg: An instance to check. type: Any

    Returns:
      True for unicode instances, False otherwise. rtype: bool
    """
    return hasattr(arg, "encode")

_STRING_TYPE = type("")

def is_string(arg):
    """Checks if provided instance has a string type.

    Args:
      arg: An instance to check. type: Any

    Returns:
      True for string instances, False otherwise. rtype: bool
    """
    return type(arg) == _STRING_TYPE

_LIST_TYPE = type([])

def is_list(arg):
    """Checks if provided instance has a list type.

    Args:
      arg: An instance to check. type: Any

    Returns:
      True for list instances, False otherwise. rtype: bool
    """
    return type(arg) == _LIST_TYPE

_DICT_TYPE = type({})

def is_dict(arg):
    """Checks if provided instance has a dict type.

    Args:
      arg: An instance to check. type: Any

    Returns:
      True for dict instances, False otherwise. rtype: bool
    """
    return type(arg) == _DICT_TYPE

_SET_TYPE = type(set())

def is_set(arg):
    """Checks if provided instance has a set type.

    Args:
      arg: An instance to check. type: Any

    Returns:
      True for set instances, False otherwise. rtype: bool
    """
    return type(arg) == _SET_TYPE

_TUPLE_TYPE = type(())

def is_tuple(arg):
    """Checks if provided instance has a tuple type.

    Args:
      arg: An instance to check. type: Any

    Returns:
      True for tuple instances, False otherwise. rtype: bool
    """
    return type(arg) == _TUPLE_TYPE

def is_collection(arg):
    """Checks if provided instance is a collection subtype.

    This will either be a dict, list, or tuple.
    """
    return is_dict(arg) or is_list(arg) or is_tuple(arg)

_BOOL_TYPE = type(True)

def is_bool(arg):
    """Checks if provided instance is a boolean value.

    Args:
      arg: An instance of check. type: Any

    Returns:
      True for boolean values, False otherwise. rtype: bool
    """
    return type(arg) == _BOOL_TYPE

_NUMBER_TYPE = type(1)

def is_number(arg):
    """Checks if provided instance is a number value.

    Args:
      arg: An instance of check. type: Any

    Returns:
      True for number values, False otherwise. rtype: bool
    """
    return type(arg) == _NUMBER_TYPE

_STRUCT_TYPE = type(struct())  # Starlark returns the same type for all structs

def is_struct(arg):
    """Checks if provided instance is a struct value.

    Args:
      arg: An instance to check. type: Any

    Returns:
      True for struct values, False otherwise. rtype: bool
    """
    return type(arg) == _STRUCT_TYPE

def _func():
    pass

_FUNCTION_TYPE = type(_func)

def is_function(args):
    """Checks if provided instance is a function value.

    Args:
      arg: An instance to check. type: Any

    Returns:
      True for function values, False otherwise. rtype: function
    """
    return type(args) == _FUNCTION_TYPE

type_utils = struct(
    is_bool = is_bool,
    is_number = is_number,
    is_string = is_string,
    is_unicode = is_unicode,
    is_list = is_list,
    is_dict = is_dict,
    is_set = is_set,
    is_tuple = is_tuple,
    is_collection = is_collection,
    is_select = is_select,
    is_struct = is_struct,
    is_function = is_function,
)
