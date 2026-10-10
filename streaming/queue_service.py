"""Executable request/credit state machines. Integer nanoseconds; no fluid server.

The backend is explicitly a replaceable transaction emulator, NOT a DDR model.
The calendar issues work; completion bytes come only from backend callbacks.
No service-curve function is used here. See run_cases.py for independent checks.
"""
from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass, field
import heapq
import itertools

CLIENTS = ("air_Tx0_read", "air_Tx1_read", "air_Rx0_write", "air_Rx1_write",
           "host_Tx0_write", "host_Tx1_write", "host_Rx0_read", "host_Rx1_read")
T, FRAGMENT = 100_000, 4096
QUOTAS = (9, 9, 9, 9, 45, 45, 45, 45)


class Loop:
    def __init__(self):
        self.now = 0
        self.events = []
        self.ids = itertools.count()

    def at(self, t, fn, *args):
        assert t >= self.now, (t, self.now)
        heapq.heappush(self.events, (t, next(self.ids), fn, args))

    def run(self, until):
        while self.events and self.events[0][0] <= until:
            self.now, _, fn, args = heapq.heappop(self.events)
            fn(*args)
        self.now = until


class Credit:
    """A unique token is reserved once and released once, by an observed event."""
    def __init__(self, name, capacity):
        self.name, self.capacity = name, capacity
        self.tokens = {}
        self.used = self.peak = self.granted = self.released = 0
        self.checks = 0

    def fits(self, n):
        return 0 <= n <= self.capacity - self.used

    def reserve(self, key, n):
        assert key not in self.tokens and self.fits(n), (self.name, key, n)
        self.tokens[key] = n
        self.used += n
        self.granted += n
        self.peak = max(self.peak, self.used)
        self.check()

    def release(self, key):
        n = self.tokens.pop(key)  # duplicate release is a hard error
        self.used -= n
        self.released += n
        self.check()

    def check(self):
        assert 0 <= self.used <= self.capacity
        assert self.granted - self.released == self.used
        self.checks += 1

    def report(self):
        assert self.used == sum(self.tokens.values())
        return dict(capacity=self.capacity, peak=self.peak, used=self.used,
                    granted=self.granted, released=self.released,
                    conservation_error=self.granted-self.released-self.used,
                    transition_checks=self.checks)


class Arena:
    """Packed byte spans, not one page per packet. Free-list merges released spans.

    A page may have multiple owners of disjoint ranges. Real ECC/RMW locking and
    byte masks must be supplied by the memory adapter. Addresses are pool-relative.
    """
    def __init__(self, name, base, capacity):
        self.credit = Credit(name, capacity)
        self.base, self.capacity = base, capacity
        self.free = [(0, capacity)]
        self.held = {}

    def reserve(self, key, n):
        assert self.credit.fits(n)
        left, spans = n, []
        while left:
            start, size = self.free[0]
            k = min(size, left)
            spans.append((self.base+start, k))
            if k == size:
                self.free.pop(0)
            else:
                self.free[0] = (start+k, size-k)
            left -= k
        self.held[key] = spans
        self.credit.reserve(key, n)
        return spans

    def release(self, key):
        self.free.extend((a-self.base, n) for a, n in self.held.pop(key))
        self.free.sort()
        merged = []
        for a, n in self.free:
            if merged and sum(merged[-1]) == a:
                p, m = merged[-1]
                merged[-1] = (p, m+n)
            else:
                merged.append((a, n))
        self.free = merged
        self.credit.release(key)

    def check(self):
        spans = self.free + [(a-self.base, n) for ss in self.held.values() for a, n in ss]
        end = 0
        for a, n in sorted(spans):
            assert a == end and n > 0
            end += n
        assert end == self.capacity
        assert sum(n for _, n in self.free) + self.credit.used == self.capacity


def subspans(spans, offset, length):
    """Translate a byte range; split at both allocation and 4KiB boundaries."""
    result = []
    for a, n in spans:
        if offset >= n:
            offset -= n
            continue
        a, n = a+offset, min(n-offset, length)
        offset = 0
        while n:
            k = min(n, FRAGMENT-a % FRAGMENT)
            result.append((a, k))
            a, n, length = a+k, n-k, length-k
        if not length:
            break
    assert length == 0
    return result


class Memory:
    def __init__(self):
        self.pages = {}
        self.write_bytes = self.read_bytes = self.compares = 0

    def write(self, spans, data):
        off = 0
        for a, n in spans:
            page = self.pages.setdefault(a//FRAGMENT, bytearray(FRAGMENT))
            page[a % FRAGMENT:a % FRAGMENT+n] = data[off:off+n]
            off += n
        assert off == len(data)
        self.write_bytes += off

    def read(self, spans):
        out = b"".join(bytes(self.pages[a//FRAGMENT][a % FRAGMENT:a % FRAGMENT+n]) for a, n in spans)
        self.read_bytes += len(out)
        return out


@dataclass
class Work:
    key: str
    client: int
    length: int
    spans: list
    payload: bytes
    enqueued: int
    destination: str = "default"
    board: int = 0
    epoch: int = 1
    mapping_version: int = 1
    completion_owner: str = "queue"
    gate: object = lambda: True
    finish: object = lambda w: None
    cancel_finish: object = lambda w: None
    cursor: int = 0
    completed: int = 0
    outstanding: int = 0
    cancel_pending: bool = False
    terminal: bool = False
    first_eligible: int | None = None
    first_accept: int | None = None
    last_complete: int | None = None


class VOQ:
    """Byte deficit round robin across destinations; FIFO within each destination.

    Only one quantum is accrued on a visit; blocked/empty queues cannot bank it.
    The visit may pack/split multiple packets into a logical fragment.
    """
    def __init__(self, quantum=4096):
        self.q = {}
        self.order = deque()
        self.deficit = defaultdict(int)
        self.quantum = quantum
        self.open_visit = None

    def put(self, work):
        d = work.destination
        if d not in self.q:
            self.q[d] = deque()
            self.order.append(d)
        self.q[d].append(work)

    def eligible(self, now):
        found = False
        for d in self.order:
            while self.q[d] and (self.q[d][0].terminal or self.q[d][0].cancel_pending):
                self.q[d].popleft()
            if self.q[d] and self.q[d][0].gate():
                w = self.q[d][0]
                if w.first_eligible is None:
                    w.first_eligible = now
                found = True
        return found

    def take(self, budget, now):
        result = []
        # Bounded scans of the currently registered destinations; no polling loop.
        missed = 0
        while budget and self.order and missed < len(self.order):
            d = self.order[0]
            q = self.q[d]
            while q and (q[0].terminal or q[0].cancel_pending):
                q.popleft()
            if not q or not q[0].gate():
                self.deficit[d] = 0
                self.open_visit = None
                self.order.rotate(-1)
                missed += 1
                continue
            if self.open_visit != d:
                self.deficit[d] += self.quantum
                self.open_visit = d
            w = q[0]
            if w.first_eligible is None:
                w.first_eligible = now
            n = min(budget, self.deficit[d], w.length-w.cursor)
            result.append((w, w.cursor, n))
            if w.first_accept is None:
                w.first_accept = now
            w.cursor += n
            w.outstanding += 1
            budget -= n
            self.deficit[d] -= n
            missed = 0
            if w.cursor == w.length:
                q.popleft()
            if not self.deficit[d] or not q:
                self.deficit[d] = 0
                self.open_visit = None
                self.order.rotate(-1)
        return result


class Backend:
    """Single in-flight emulator. Bounds are supplied assumptions, not evidence.

    Includes a deterministic variable completion delay and optional long stalls.
    The positive adapter's 400..448ns delay is deliberately separate from quotas.
    This stricter slot fit must NOT be inferred from 70% average DDR efficiency.
    """
    def __init__(self, loop, memory, long_every=0, long_ns=0):
        self.loop, self.memory = loop, memory
        self.busy = False
        self.serial = 0
        self.long_every, self.long_ns = long_every, long_ns
        self.max_latency = 0

    def submit(self, pieces, callback):
        assert not self.busy and pieces
        self.busy = True
        self.serial += 1
        n = sum(x[2] for x in pieces)
        # Startup plus payload length; variable emulator delay, not a target curve.
        delay = 32 + (n*368+4095)//4096 + (self.serial % 7)*8
        if self.long_every and self.serial % self.long_every == 0:
            delay += self.long_ns
        self.max_latency = max(self.max_latency, delay)
        self.loop.at(self.loop.now+delay, self._done, pieces, callback)
        return delay

    def _done(self, pieces, callback):
        self.busy = False
        for w, offset, n in pieces:
            refs = subspans(w.spans, offset, n)
            data = w.payload[offset:offset+n]
            if w.client in (2, 3, 4, 5):
                self.memory.write(refs, data)
            else:
                assert self.memory.read(refs) == data, (w.key, offset, n)
                self.memory.compares += 1
        callback(pieces)


class Arbiter:
    def __init__(self, loop, backend):
        self.loop, self.backend = loop, backend
        self.q = [VOQ() for _ in CLIENTS]
        self.calendar = [c for c, n in enumerate(QUOTAS) for _ in range(n)]
        self.borrow_cursor = 0
        self.works = []
        self.requests = []
        self.completed = [[] for _ in CLIENTS]
        self.slot_misses = []
        self.borrowed = [0]*8
        self.queue_peak = [0]*8
        self.pending = [0]*8
        self.cancelled_prefixes = []
        self.on_slot_miss = lambda record: None

    def enqueue(self, w):
        assert 0 < w.length and sum(n for _, n in w.spans) == w.length
        if w.gate():
            w.first_eligible = self.loop.now
        self.works.append(w)
        self.q[w.client].put(w)
        self.pending[w.client] += w.length
        self.queue_peak[w.client] = max(self.queue_peak[w.client], self.pending[w.client])

    def cancel(self, w):
        if w.terminal:
            return "already_terminal"
        if w.cancel_pending:
            return "cancel_pending"
        w.cancel_pending = True
        self.pending[w.client] -= w.length-w.cursor
        if not w.outstanding:
            self._cancel_done(w)
        return "draining" if not w.terminal else "cancelled"

    def _cancel_done(self, w):
        assert not w.outstanding
        w.terminal = True
        self.cancelled_prefixes.append(dict(key=w.key, completed_prefix=w.completed,
                                            length=w.length, time_ns=self.loop.now))
        w.cancel_finish(w)

    def start(self, end):
        for s in range((end*len(self.calendar)+T-1)//T):
            self.loop.at(s*T//len(self.calendar), self._slot, s)

    def _slot(self, s):
        owner = self.calendar[s % len(self.calendar)]
        if self.backend.busy:
            record = dict(slot=s, time_ns=self.loop.now, owner=owner)
            self.slot_misses.append(record)
            self.on_slot_miss(record)
            return
        client = owner if self.q[owner].eligible(self.loop.now) else None
        if client is None:
            for k in range(8):
                c = (self.borrow_cursor+k) % 8
                if self.q[c].eligible(self.loop.now):
                    client = c
                    self.borrow_cursor = (c+1) % 8
                    break
        if client is None:
            return
        pieces = self.q[client].take(FRAGMENT, self.loop.now)
        if not pieces:
            return
        length = sum(n for _, _, n in pieces)
        self.pending[client] -= length
        req = dict(request_id=len(self.requests), client=client, channel=client % 2,
                   operation="write" if client in (2, 3, 4, 5) else "read",
                   length=length, calendar_owner=owner, slot=s,
                   accepted_ns=self.loop.now, completed_ns=None,
                   ranges=[dict(object=w.key, offset=o, length=n,
                                pages=subspans(w.spans, o, n), epoch=w.epoch,
                                completion_owner=w.completion_owner) for w, o, n in pieces])
        self.requests.append(req)
        if client != owner:
            self.borrowed[client] += length
        self.backend.submit(pieces, lambda p: self._done(req, p))

    def _done(self, req, pieces):
        req["completed_ns"] = self.loop.now
        self.completed[req["client"]].append((self.loop.now, req["length"]))
        for w, _, n in pieces:
            w.completed += n
            w.outstanding -= 1
            w.last_complete = self.loop.now
            if w.cancel_pending:
                if not w.outstanding:
                    self._cancel_done(w)
            elif w.completed == w.length:
                assert w.outstanding == 0 and not w.terminal
                w.terminal = True
                w.finish(w)

    def metrics(self):
        out = {}
        for c, name in enumerate(CLIENTS):
            ws = [w for w in self.works if w.client == c]
            times = [t for t, _ in self.completed[c]]
            out[name] = dict(completed_bytes=sum(n for _, n in self.completed[c]),
                longest_completion_gap_ns=max((b-a for a, b in zip(times, times[1:])), default=0),
                max_enqueue_to_first_accept_ns=max((w.first_accept-w.enqueued for w in ws if w.first_accept is not None), default=0),
                max_first_observed_eligible_to_accept_ns=max((w.first_accept-w.first_eligible for w in ws if w.first_accept is not None), default=0),
                max_enqueue_to_complete_ns=max((w.last_complete-w.enqueued for w in ws if w.terminal and not w.cancel_pending), default=0),
                pending_bytes=self.pending[c], queue_peak_bytes=self.queue_peak[c],
                borrowed_bytes=self.borrowed[c], unfinished_objects=sum(not w.terminal for w in ws))
        return out

    def destination_metrics(self):
        out = {}
        for w in self.works:
            key = CLIENTS[w.client]+"/"+w.destination
            row = out.setdefault(key, dict(offered_bytes=0, completed_bytes=0,
                                          max_enqueue_to_accept_ns=0, unfinished_objects=0))
            row["offered_bytes"] += w.length
            row["completed_bytes"] += w.completed
            row["unfinished_objects"] += not w.terminal
            if w.first_accept is not None:
                row["max_enqueue_to_accept_ns"] = max(row["max_enqueue_to_accept_ns"], w.first_accept-w.enqueued)
        return out
