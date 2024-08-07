from ctypes import *
from pathlib import PurePath
from typing import Optional

libpath = PurePath(__file__).parent / "lib/librational.so"
lib = CDLL(libpath)

lib.from_float.argtypes = [c_double]
lib.from_float.restype = c_long


class ToFloatResult(Structure):
    _fields_ = [("valid", c_bool), ("value", c_double)]


lib.to_float.argtypes = [c_long]
lib.to_float.restype = ToFloatResult


def declare_binop(obj):
    obj.argtypes = [c_long, c_long]
    obj.restype = c_long

def declare_cond(obj):
    obj.argtypes = [c_long, c_long]
    obj.restype = c_int

declare_binop(lib.add)
declare_binop(lib.sub)
declare_binop(lib.mul)
declare_binop(lib.div)
declare_cond(lib.eq)
declare_cond(lib.neq)
declare_cond(lib.gt)
declare_cond(lib.lt)
declare_cond(lib.gte)
declare_cond(lib.lte)

lib.is_zero.argtypes = [c_long]
lib.is_zero.restype = c_int

class String(Structure):
    _fields_ = [("len", c_uint), ("ptr", c_char_p)]


lib.to_string.argtypes = [c_long]
lib.to_string.restype = String
lib.free_string.argtypes = [String]
lib.free_string.restype = None
lib.from_string.argtypes = [c_char_p, c_ulong]
lib.from_string.restype = c_long

lib.init()


def deinit():
    """free resources currently used by the rational library"""
    lib.deinit()


class RationalException(Exception):
    pass


def _validate_handle(handle):
    if handle < 0:
        raise RationalException()


class Rational:
    def __init__(self, value):
        self.handle = lib.from_float(float(value))

    @classmethod
    def from_handle(cls, handle):
        this = super().__new__(cls)
        this.handle = handle
        return this

    @classmethod
    def from_string(cls, string):
        cstr = c_char_p(string.encode('utf-8'))
        handle = lib.from_string(cstr, len(string))
        _validate_handle(handle)

        this = super().__new__(cls)
        this.handle = handle
        return this

    def __del__(self):
        lib.delete(self.handle)

    def is_zero(self):
        result = lib.is_zero(self.handle)
        if result < 0:
            return RationalException("invalid handle")
        return result != 0

    def _binop(self, func, other):
        res_handle = func(self.handle, other.handle)
        _validate_handle(res_handle)
        return Rational.from_handle(res_handle)

    def _cond(self, func, other):
        res = func(self.handle, other.handle)
        if res < 0:
            return RationalException("conditional failure")
        return res != 0

    def __add__(self, other):
        return self._binop(lib.add, other)

    def __sub__(self, other):
        return self._binop(lib.sub, other)

    def __mul__(self, other):
        return self._binop(lib.mul, other)

    def __truediv__(self, other):
        if other.is_zero():
            return RationalException("attempted to divide by zero")

        return self._binop(lib.div, other)

    def __eq__(self, other):
        return self._cond(lib.eq, other)

    def __ne__(self, other):
        return self._cond(lib.neq, other)

    def __lt__(self, other):
        return self._cond(lib.lt, other)

    def __gt__(self, other):
        return self._cond(lib.gt, other)

    def __le__(self, other):
        return self._cond(lib.lte, other)

    def __ge__(self, other):
        return self._cond(lib.gte, other)

    def __float__(self) -> float:
        res = lib.to_float(self.handle)
        if not res.valid:
            raise RationalException("this value cannot be converted to a float")
        return res.value

    def __str__(self) -> str:
        cstr = lib.to_string(self.handle)
        if cstr.ptr is None:
            raise RationalException("failed to convert value to string")
        res = cstr.ptr.decode("utf8")
        lib.free_string(cstr)
        return res
