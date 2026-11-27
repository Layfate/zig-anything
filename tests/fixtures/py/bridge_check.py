"""Used by the end-to-end tests: calls the scale_in_place bridge and prints
what the calls did to their arguments."""
import importlib.util
import json
import os

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("port", os.path.join(here, "..", "zig-port", "scale_in_place", "bridge", "port.py"))
port = importlib.util.module_from_spec(spec)
spec.loader.exec_module(port)
xs = [1.0, 2.0, 3.0]
n = port.scale_in_place(xs, 2.0)
ys = [5.0]
port.scale_in_place_batch([[ys, 3.0]])
print(json.dumps({"n": n, "xs": xs, "ys": ys, "floats": all(type(x) is float for x in xs + ys)}))
