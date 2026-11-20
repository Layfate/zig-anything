"""A tiny app for the profile end-to-end test: digit_sum is the hot spot."""
from mathutil import digit_sum, fizzbuzz

total = 0
for i in range(100000):
    total += digit_sum(i)
print(total, fizzbuzz(15))
