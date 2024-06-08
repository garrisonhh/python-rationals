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


declare_binop(lib.add)
declare_binop(lib.mul)
declare_binop(lib.div)


class String(Structure):
    _fields_ = [("len", c_uint), ("ptr", c_char_p)]


lib.to_string.argtypes = [c_long]
lib.to_string.restype = String
lib.free_string.argtypes = [String]
lib.free_string.restype = None

lib.init()


def deinit():
    """free resources currently used by the rational library"""
    lib.deinit()


class RationalException(Exception):
    pass


def _validate_handle(handle):
    if handle < 0:
        raise RationalException("rational library out of memory")


class Rational:
    def __init__(self, value):
        self.handle = lib.from_float(c_double(value))

    @classmethod
    def from_handle(cls, handle):
        this = super().__new__(cls)
        this.handle = handle
        return this

    def __del__(self):
        lib.delete(self.handle)

    def _binop(self, func, other):
        res_handle = func(self.handle, other.handle)
        _validate_handle(res_handle)
        return Rational.from_handle(res_handle)

    def __add__(self, other):
        return self._binop(lib.add, other)

    def __mul__(self, other):
        return self._binop(lib.mul, other)

    def __truediv__(self, other):
        return self._binop(lib.div, other)

    def to_float_fallible(self) -> Optional[float]:
        """for those who hate python's error handling philosophy"""
        res = lib.to_float(self.handle)
        if not res.valid:
            return None
        return res.value

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
