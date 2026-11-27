"""Functions with side effects, used by the end-to-end tests."""


def save_note(name: str) -> int:
    with open(name, "w") as f:
        f.write("written by the original")
    return len(name)


def scale_in_place(xs: list, k: float) -> int:
    for i in range(len(xs)):
        xs[i] *= k
    return len(xs)
