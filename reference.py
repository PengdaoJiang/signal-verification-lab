from __future__ import annotations

import ctypes
from pathlib import Path


def validate_q15(values):
    if any(type(x) is not int or not -32768 <= x <= 32767 for x in values):
        raise ValueError("Q1.15 values must be signed 16-bit integers")


def reference(samples, coefficients):
    validate_q15(samples)
    validate_q15(coefficients)
    if len(coefficients) != 3:
        raise ValueError("exactly three coefficients are required")
    # Deliberately use indexed convolution, not the C kernel's mutable delay line.
    return [max(-32768, min(32767, sum(coefficients[k] * samples[n - k]
            for k in range(3) if n >= k) // 32768)) for n in range(len(samples))]


def compare(expected, observed):
    for index, (left, right) in enumerate(zip(expected, observed)):
        if left != right:
            return {"match": False, "kind": "value", "index": index, "expected": left, "observed": right}
    if len(expected) != len(observed):
        return {"match": False, "kind": "length", "index": min(len(expected), len(observed)),
                "expected_length": len(expected), "observed_length": len(observed)}
    return {"match": True, "samples": len(expected)}


class State(ctypes.Structure):
    _fields_ = [("previous", ctypes.c_int16 * 2)]


class CFilter:
    def __init__(self, library, coefficients):
        validate_q15(coefficients)
        if len(coefficients) != 3:
            raise ValueError("exactly three coefficients are required")
        self.library = ctypes.CDLL(str(Path(library).resolve()))
        pointer = ctypes.POINTER(ctypes.c_int16)
        self.library.fir_reset.argtypes = [ctypes.POINTER(State)]
        self.library.fir_reset.restype = None
        self.library.fir_process.argtypes = [ctypes.POINTER(State), pointer, pointer, pointer, ctypes.c_size_t]
        self.library.fir_process.restype = None
        self.state = State()
        self.coefficients = (ctypes.c_int16 * 3)(*coefficients)
        self.reset()

    def reset(self):
        self.library.fir_reset(ctypes.byref(self.state))

    def process(self, samples):
        validate_q15(samples)
        input_values = (ctypes.c_int16 * len(samples))(*samples)
        output_values = (ctypes.c_int16 * len(samples))()
        self.library.fir_process(ctypes.byref(self.state), self.coefficients,
                                 input_values, output_values, len(samples))
        return list(output_values)
