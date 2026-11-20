"""A tiny word-count tool used by the end-to-end tests for program units."""
import sys


def count(text):
    return text.count("\n"), len(text.split()), len(text)


def main(argv):
    flags = [a for a in argv if a.startswith("-") and a != "-"]
    files = [a for a in argv if a not in flags]
    for f in flags:
        if f not in ("-l", "-w", "-c"):
            sys.stderr.write("wc: unknown option %s\n" % f)
            return 2
    show = [f for f in ("-l", "-w", "-c") if f in flags] or ["-l", "-w", "-c"]
    for name in files or ["-"]:
        if name == "-":
            data = sys.stdin.buffer.read()
        else:
            try:
                with open(name, "rb") as fh:
                    data = fh.read()
            except OSError:
                sys.stderr.write("wc: %s: no such file\n" % name)
                return 1
        lines, words, chars = count(data.decode("utf-8"))
        values = {"-l": lines, "-w": words, "-c": chars}
        out = " ".join(str(values[f]) for f in show)
        print(out if name == "-" else out + " " + name)
    return 0


sys.exit(main(sys.argv[1:]))
