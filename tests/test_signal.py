import os
import random
import unittest

from reference import CFilter, compare, reference


class ReferenceTests(unittest.TestCase):
    def test_impulse(self):
        self.assertEqual(reference([16384, 0, 0, 0], [8192, 16384, 8192]), [4096, 8192, 4096, 0])

    def test_negative_floor(self):
        self.assertEqual(reference([-1], [1, 0, 0]), [-1])

    def test_positive_saturation(self):
        self.assertEqual(reference([32767] * 3, [32767] * 3)[-1], 32767)

    def test_negative_saturation(self):
        self.assertEqual(reference([-32768] * 3, [32767] * 3)[-1], -32768)

    def test_zero_length(self):
        self.assertEqual(reference([], [1, 2, 3]), [])

    def test_bad_input(self):
        for samples in [[32768], [-32769], [True], [0.5]]:
            with self.assertRaises(ValueError):
                reference(samples, [1, 2, 3])

    def test_bad_coefficients(self):
        with self.assertRaises(ValueError):
            reference([1], [1, 2])

    def test_value_fault(self):
        self.assertEqual(compare([1, 2], [1, 3])["index"], 1)

    def test_length_fault(self):
        self.assertEqual(compare([1, 2], [1])["kind"], "length")

    def test_exact_match(self):
        self.assertTrue(compare([1, -2], [1, -2])["match"])


@unittest.skipUnless(os.environ.get("SIGNAL_FIR_LIBRARY"), "compiled C library not configured")
class CrossLanguageTests(unittest.TestCase):
    def setUp(self):
        self.library = os.environ["SIGNAL_FIR_LIBRARY"]
        self.coeff = [8192, 16384, 8192]
        self.kernel = CFilter(self.library, self.coeff)

    def test_random(self):
        rng = random.Random(41)
        values = [rng.randint(-32768, 32767) for _ in range(4096)]
        self.assertEqual(self.kernel.process(values), reference(values, self.coeff))

    def test_block_boundaries(self):
        values = [32767, -32768, 3, -7, 600, 0, 0]
        observed = self.kernel.process(values[:2]) + self.kernel.process([]) + self.kernel.process(values[2:])
        self.assertEqual(observed, reference(values, self.coeff))

    def test_reset(self):
        self.kernel.process([32767, 32767])
        self.kernel.reset()
        self.assertEqual(self.kernel.process([0, 0, 0]), [0, 0, 0])

    def test_negative_rounding(self):
        kernel = CFilter(self.library, [1, -1, 1])
        values = [-1, 1, -3, 7]
        self.assertEqual(kernel.process(values), reference(values, [1, -1, 1]))

    def test_saturation_both_signs(self):
        for value in [32767, -32768]:
            kernel = CFilter(self.library, [32767] * 3)
            self.assertEqual(kernel.process([value] * 8), reference([value] * 8, [32767] * 3))

    def test_full_receipt(self):
        from verify import run
        receipt = run(self.library)
        self.assertTrue(receipt["all_passed"])
        self.assertEqual(receipt["case_count"], 80)


if __name__ == "__main__":
    unittest.main()
