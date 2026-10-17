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


def app_of(cls) -> str:
    """The app class a problem uses: first known app class instantiated in its class source,
    else in its module, else via a problem parameter like `app_name="astronomy_shop"`."""
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
