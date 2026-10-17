#!/usr/bin/env python3
"""Map SREGym problem ids to the application they run on, and that application to its source.

Prints one line per problem: `<problem-id> <app-key> <namespace> <source-dir-or->`.
The app is read from the problem class's source (`app=SomeApp()`), so nothing is deployed.

Usage (from the SREGym checkout, with its venv): python ops/sregym-problem-app.py [problem-id ...]
"""
import inspect
import os
import re
import sys

from sregym.conductor.problems.registry import ProblemRegistry

SRC = os.path.expanduser("~/sregym-src")
APPS = {  # class name -> (app key, namespace, source dir)
    "AstronomyShop": ("astronomy-shop", "astronomy-shop", f"{SRC}/astronomy-shop"),
    "HotelReservation": ("hotel-reservation", "hotel-reservation", f"{SRC}/DeathStarBench/hotelReservation"),
    "SocialNetwork": ("social-network", "social-network", f"{SRC}/DeathStarBench/socialNetwork"),
    "TrainTicket": ("train-ticket", "train-ticket", f"{SRC}/train-ticket"),
}


KNOWN = ["BlueprintHotelReservation", "AstronomyShop", "HotelReservation", "SocialNetwork", "TrainTicket",
         "FleetCast", "FlightTicket", "Saleor", "SlackSpine", "Frappe", "Gitea", "Gitlab", "Mattermost", "TiDB"]


def resolve_factory(obj):
    """Registry entries are often lambdas (`lambda: MongoDBRevokeAuth(faulty_service=...)`).
    Resolve the class such a lambda calls so we read the problem's own module, never the
    registry's (which names every app and made the first one win)."""
    if inspect.isclass(obj):
        return obj
    try:
        src = inspect.getsource(obj)
    except (OSError, TypeError):
        return obj
    m = re.search(r"lambda[^:]*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(", src)
    if not m:
        return obj
    mod = sys.modules.get(getattr(obj, "__module__", ""), None)
    return getattr(mod, m.group(1), obj) if mod else obj


APP_NAME_ARG = {"astronomy_shop": "AstronomyShop", "hotel_reservation": "HotelReservation",
                "social_network": "SocialNetwork", "train_ticket": "TrainTicket"}


def app_of(cls) -> str:
    """The app class a problem uses. A registry lambda's explicit `app_name="..."` argument wins
    (generic classes like DuplicatePVCMounts serve several apps); then the first known app class
    instantiated in the problem's class source, else in its module."""
    try:
        lam = inspect.getsource(cls) if not inspect.isclass(cls) else ""
    except (OSError, TypeError):
        lam = ""
    m = re.search(r"app_name\s*=\s*[\"']([a-z_]+)[\"']", lam)
    if m and m.group(1) in APP_NAME_ARG:
        return APP_NAME_ARG[m.group(1)]
    cls = resolve_factory(cls)
    if not inspect.isclass(cls):
        return "?"
    texts = []
    try:
        texts.append(inspect.getsource(cls))
    except (OSError, TypeError):
        pass
    try:
        texts.append(open(inspect.getsourcefile(cls)).read())
    except (OSError, TypeError):
        pass
    for t in texts:
        hits = [(m.start(), k) for k in KNOWN for m in re.finditer(rf"\b{k}\s*\(", t)]
        if hits:
            return min(hits)[1]
    for t in texts:
        low = t.lower()
        for k, needle in (("AstronomyShop", "astronomy"), ("HotelReservation", "hotel"), ("SocialNetwork", "social"), ("TrainTicket", "train")):
            if needle in low:
                return k
    return "?"


def main() -> int:
    reg = ProblemRegistry()
    ids = sys.argv[1:] or reg.get_problem_ids()
    for pid in ids:
        cls = reg.PROBLEM_REGISTRY.get(pid)
        name = app_of(cls) if cls is not None else "?"
        key, ns, src = APPS.get(name, (name, "-", "-"))
        if src != "-" and not os.path.isdir(src):
            src = "-"
        print(pid, key, ns, src)
    return 0


if __name__ == "__main__":
    sys.exit(main())
