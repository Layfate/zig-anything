"""Math helpers used by the end-to-end tests."""


def fizzbuzz(n: int) -> str:
    if n % 15 == 0:
        return "FizzBuzz"
    if n % 3 == 0:
        return "Fizz"
    if n % 5 == 0:
        return "Buzz"
    return str(n)


def digit_sum(n: int) -> int:
    if n < 0:
        raise ValueError("negative")
    return sum(int(d) for d in str(n))
