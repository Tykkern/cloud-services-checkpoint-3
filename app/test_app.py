import unittest

from app import greeting


class GreetingTest(unittest.TestCase):
    def test_greeting(self):
        self.assertEqual(greeting("world"), "Hello, world!")


if __name__ == "__main__":
    unittest.main()
