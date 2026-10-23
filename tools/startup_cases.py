"""Self-authored inputs for the observed two-card startup update contract."""
import itertools


def cases():
    events = [(0,0), (1,1), (1,2), (1,3), (1,4)]
    for card, waiting, elapsed, delta, skip, (complete, transition) in itertools.product(
            (0,1), (0,1), (0,1999,2000,29999,30000,2147483647,2147483648,4294967295),
            (-1,0,1,16,2000,30000,2147483647), (0,1,2,3,255), events):
        yield {"state": [card,waiting,0,elapsed], "input": [delta,transition,complete,skip]}
