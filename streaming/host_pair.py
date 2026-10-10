"""Two software endpoints around the queue engine; complete normal MAC objects only.

No network driver, DDR timing, PHY decoder or trusted-MAC-start implementation.
Link serialization and propagation are explicit scenario inputs. Completion,
publication, peer release and host consumption are distinct events.
"""
from __future__ import annotations
from collections import deque
from dataclasses import dataclass
import hashlib

from queue_service import Arena, Arbiter, Backend, Credit, Loop, Memory, VOQ, Work, subspans


class Link:
    def __init__(self, loop, name, bits_per_ns=29, propagation_ns=2000):
        self.loop, self.name = loop, name
        self.rate, self.propagation = bits_per_ns, propagation_ns
        self.q, self.scheduled = VOQ(), False
        self.records = []

    def put(self, w):
        self.q.put(w)
        if not self.scheduled:
            self.scheduled = True
            self.loop.at(self.loop.now, self.launch)

    def launch(self):
        pieces = self.q.take(4096, self.loop.now)
        if not pieces:
            self.scheduled = False
            return
        n = sum(x[2] for x in pieces)
        serial = (n*8+self.rate-1)//self.rate
        self.records.append(dict(accepted_ns=self.loop.now, serialized_ns=self.loop.now+serial,
                                 completed_ns=self.loop.now+serial+self.propagation, length=n))
        self.loop.at(self.loop.now+serial+self.propagation, self.done, pieces)
        self.loop.at(self.loop.now+serial, self.launch)

    def done(self, pieces):
        for w, _, n in pieces:
            w.completed += n
            w.outstanding -= 1
            if w.completed == w.length:
                assert w.outstanding == 0
                w.terminal = True
                w.finish(w)


@dataclass
class Packet:
    key: str
    direction: str
    channel: int
    destination: str
    content_length: int
    payload_reference: list
    payload: bytes
    born_ns: int
    completion_owner: str
    board: int = 0
    mapping_version: int = 1
    epoch: int = 1
    generation: int = 1
    state: str = "RESERVED"
    cancel_pending: bool = False
    work: Work | None = None
    published_ns: int | None = None
    terminal_ns: int | None = None
    transfer_attempt: int = 0
    host_key: str | None = None
    consumed: int = 0


class Pair:
    def __init__(self, cfg):
        self.loop, self.memory = Loop(), Memory()
        self.backend = Backend(self.loop, self.memory)
        self.arb = Arbiter(self.loop, self.backend)
        self.arb.on_slot_miss = self.service_fault
        self.service_faulted = False
        self.cfg = cfg
        self.tx, self.rx = [], []
        for ch in range(2):
            for kind, target in (("Tx", self.tx), ("Rx", self.rx)):
                part = next(x for x in cfg["capacity"]["relative_partitions"] if x["name"] == kind+str(ch))
                target.append(Arena(kind+str(ch), part["relative_byte_offset"], part["business_usable_bytes"]))
        self.tx_stage = [Credit("host_Tx_stage"+str(i), 524288) for i in range(2)]
        self.rx_stage = [Credit("air_Rx_stage"+str(i), 1048576) for i in range(2)]
        self.tx_fifo = [Credit("air_Tx_fifo"+str(i), 65536) for i in range(2)]
        self.rx_out = [Credit("host_Rx_stage"+str(i), 524288) for i in range(2)]
        self.upload_credit = [Credit("host_upload_inflight"+str(i), 65536) for i in range(2)]
        self.host_ring = [Credit("host_Rx_ring"+str(i), 1073741824) for i in range(2)]
        # This is an explicit prototype metadata limit, not a silicon layout claim.
        self.descriptors = [Credit("active_descriptors"+str(i), 65536) for i in range(4)]
        self.to_board, self.to_host = Link(self.loop, "host_to_board"), Link(self.loop, "board_to_host")
        self.packets, self.events = {}, []
        self.seq = 0
        self.host_on = [True, True]
        self.consumer_on = [True, True]
        self.air_on = [True, True]
        self.tx_started = [False, False]
        self.tx_ready_bytes = [0, 0]
        self.destination_on = {}
        self.rx_waiting, self.tx_waiting = [deque(), deque()], [deque(), deque()]
        self.air_ready = [deque(), deque()]
        self.host_ready = [deque(), deque()]
        self.rejected_tx = self.offered_rx = self.dropped_rx = self.consumed_tx = self.delivered_rx = 0
        self.cancel_results, self.duplicate_completions = [], 0
        self.completion_seen = set()
        self.first_release_after_resume = [None, None]
        self.resume_at = [None, None]
        self.host_published = []
        self.rx_state = ["NORMAL", "NORMAL"]
        self.high_at = [None, None]
        self.high_recovery_release = [None, None]
        self.recovery_deadline_misses = []

    def event(self, name, p=None, **kw):
        self.events.append(dict(time_ns=self.loop.now, event=name, object=p.key if p else None, **kw))

    def service_fault(self, record):
        if not self.service_faulted:
            self.event("MEMORY_SERVICE_FAULT_STOP_NEW_UPLOAD_CREDIT", missed_position=record)
        self.service_faulted = True

    def new_packet(self, direction, ch, n, destination):
        self.seq += 1
        key = f"{direction}{ch}:{self.seq}"
        seed = hashlib.sha256(key.encode()).digest()
        payload = (seed*((n+31)//32))[:n]
        arena = (self.tx if direction == "TX" else self.rx)[ch]
        spans = arena.reserve(key, n)
        p = Packet(key, direction, ch, destination, n, spans, payload, self.loop.now,
                   "host_request" if direction == "TX" else "rx_delivery")
        self.packets[key] = p
        self.descriptors[ch+(0 if direction == "TX" else 2)].reserve(key, 1)
        if direction == "RX":
            self.observe_rx(ch)
        return p

    def observe_rx(self, ch):
        q = self.rx[ch].credit.used
        if q >= self.cfg["Rx_watermarks"]["high_bytes"] and self.high_at[ch] is None:
            self.high_at[ch] = self.loop.now
            self.high_recovery_release[ch] = None
            self.rx_state[ch] = "HIGH"
            self.event("RX_HIGH", channel=ch, held_bytes=q)
            self.loop.at(self.loop.now+40_000_000, self.check_recovery_deadline, ch, self.loop.now)
        if q <= self.cfg["Rx_watermarks"]["low_bytes"] and self.high_at[ch] is not None:
            self.event("RX_LOW_RETURN", channel=ch, held_bytes=q)
            self.rx_state[ch], self.high_at[ch] = "NORMAL", None

    def check_recovery_deadline(self, ch, episode):
        if self.high_at[ch] == episode and self.high_recovery_release[ch] is None:
            self.recovery_deadline_misses.append(dict(channel=ch, high_ns=episode, deadline_ns=self.loop.now))
            self.rx_state[ch] = "SERVICE_DEADLINE_MISSED"
            self.event("RX_RECOVERY_DEADLINE_MISSED", channel=ch)

    def offer_tx(self, ch, n=1992, destination="service0", hold=False):
        assert 0 < n <= 1992
        pools = (self.tx[ch].credit, self.tx_stage[ch], self.upload_credit[ch])
        if self.service_faulted or not all(x.fits(n) for x in pools) or not self.descriptors[ch].fits(1):
            self.rejected_tx += n
            self.event("TX_NOT_ACCEPTED", channel=ch, length=n)
            return None
        p = self.new_packet("TX", ch, n, destination)
        for pool in pools[1:]:
            pool.reserve(p.key, n)
        self.event("TX_CREDIT_GRANTED", p, length=n)
        if not hold:
            self.accept_upload(p)
        return p

    def accept_upload(self, p):
        assert p.state == "RESERVED" and not p.cancel_pending
        p.state = "UPLOAD_ACCEPTED"
        self.event("UPLOAD_ACCEPTED", p)
        w = self.link_work(p, lambda _: self.upload_done(p))
        self.to_board.put(w)

    def link_work(self, p, done):
        return Work(p.key, p.channel, p.content_length, p.payload_reference, p.payload,
                    self.loop.now, destination=str(p.channel), finish=done)

    def work(self, p, c, done, cancelled=None):
        return Work(p.key+f":{c}:{p.transfer_attempt}", c, p.content_length,
                    p.payload_reference, p.payload, self.loop.now,
                    destination=p.destination, board=p.board, epoch=p.epoch,
                    mapping_version=p.mapping_version, completion_owner=p.completion_owner,
                    gate=lambda: self.destination_on.get((c, p.destination), True),
                    finish=lambda _: done(p), cancel_finish=lambda _: cancelled(p) if cancelled else None)

    def upload_done(self, p):
        self.event("UPLOAD_COMPLETED", p)
        self.upload_credit[p.channel].release(p.key)
        if p.cancel_pending:
            self.cancel_tx_done(p)
            return
        p.state = "WRITE_PENDING"
        p.work = self.work(p, 4+p.channel, self.tx_write_done, self.cancel_tx_done)
        self.arb.enqueue(p.work)

    def tx_write_done(self, p):
        self.tx_stage[p.channel].release(p.key)
        p.state, p.published_ns = "PUBLISHED", self.loop.now
        self.event("TX_PACKET_PUBLISHED", p)
        self.tx_waiting[p.channel].append(p)
        self.pump_tx(p.channel)

    def pump_tx(self, ch):
        q = self.tx_waiting[ch]
        for _ in range(len(q)):
            p = q.popleft()
            if (not self.tx_fifo[ch].fits(p.content_length) or not self.air_on[ch]
                    or not self.destination_on.get((ch, p.destination), True)):
                q.append(p)
                continue
            self.tx_fifo[ch].reserve(p.key, p.content_length)
            p.state = "TX_READ_PENDING"
            p.work = self.work(p, ch, self.tx_read_done)
            self.arb.enqueue(p.work)

    def tx_read_done(self, p):
        p.state = "TX_FIFO_READY"
        self.air_ready[p.channel].append(p)
        self.tx_ready_bytes[p.channel] += p.content_length
        self.event("TX_READ_COMPLETED", p)

    def air_tick(self, ch, end):
        # Explicit 878-byte micro-transfers at 2016/750MHz; no fluid subtraction.
        if not self.tx_started[ch] and self.tx_ready_bytes[ch] >= self.cfg["local_buffers"]["air_Tx_need_bytes"]:
            self.tx_started[ch] = True
            self.event("TX_PREFILL_READY", channel=ch, ready_bytes=self.tx_ready_bytes[ch])
        left = 878 if self.air_on[ch] and self.tx_started[ch] else 0
        while left and self.air_ready[ch]:
            p = self.air_ready[ch][0]
            n = min(left, p.content_length-p.consumed)
            p.consumed += n
            self.tx_ready_bytes[ch] -= n
            self.consumed_tx += n
            left -= n
            if p.consumed == p.content_length:
                self.air_ready[ch].popleft()
                p.state = "TX_WAIT_C_RELEASE"
                # Explicit surrogate C release notification after local data use.
                # No claim that content consumption models MAC overhead/PHY timing.
                self.loop.at(self.loop.now+2000, self.tx_consumer_commit, p)
        if self.loop.now+2688 <= end:
            self.loop.at(self.loop.now+2688, self.air_tick, ch, end)

    def tx_consumer_commit(self, p):
        self.tx_fifo[p.channel].release(p.key)
        self.release_board(p, "C_PACKET_RELEASE")
        self.pump_tx(p.channel)

    def publish_rx(self, ch, n=1992, destination="host0"):
        """Input is a complete checked C DeliveryDescriptor, with known normal start."""
        assert 0 < n <= 1992
        self.offered_rx += n
        if not self.rx[ch].credit.fits(n) or not self.rx_stage[ch].fits(n) or not self.descriptors[2+ch].fits(1):
            self.dropped_rx += n
            self.rx_state[ch] = "DROP_ACTIVE"
            self.event("RF_PACKET_DROPPED", channel=ch, length=n)
            return None
        p = self.new_packet("RX", ch, n, destination)
        self.rx_stage[ch].reserve(p.key, n)
        p.state = "RX_WRITE_PENDING"
        p.work = self.work(p, 2+ch, self.rx_write_done)
        self.arb.enqueue(p.work)
        return p

    def rx_write_done(self, p):
        self.rx_stage[p.channel].release(p.key)
        p.state, p.published_ns = "PUBLISHED", self.loop.now
        self.event("RX_PACKET_PUBLISHED", p)
        self.rx_waiting[p.channel].append(p)
        self.pump_rx(p.channel)

    def pump_rx(self, ch):
        if not self.host_on[ch]:
            return
        q = self.rx_waiting[ch]
        for _ in range(len(q)):
            p = q.popleft()
            if (not self.host_ring[ch].fits(p.content_length) or not self.rx_out[ch].fits(p.content_length)
                    or not self.destination_on.get((6+ch, p.destination), True)):
                q.append(p)
                continue
            p.transfer_attempt += 1
            p.host_key = p.key+f"/pull{p.transfer_attempt}"
            self.host_ring[ch].reserve(p.host_key, p.content_length)
            self.rx_out[ch].reserve(p.host_key, p.content_length)
            self.event("HOST_RX_CREDIT_RESERVED", p, credit_token=p.host_key)
            p.state = "RX_READ_PENDING"
            p.work = self.work(p, 6+ch, self.rx_read_done, self.cancel_pull_done)
            self.arb.enqueue(p.work)

    def rx_read_done(self, p):
        p.state = "DOWNLOAD_ACCEPTED"
        self.event("RX_READ_COMPLETED", p)
        self.to_host.put(self.link_work(p, lambda _: self.download_done(p)))

    def download_done(self, p):
        # Emulator guarantees full bytes arrived. Real DMA completion is the hook.
        self.event("HOST_DMA_COMPLETED", p)
        if p.cancel_pending:
            self.cancel_pull_done(p)
            return
        p.state = "HOST_PUBLISHED"
        self.host_published.append((p.key, self.loop.now, p.content_length))
        self.host_ready[p.channel].append(p)
        self.event("HOST_PACKET_PUBLISHED", p)
        # Release acknowledgement is separate from host publication.
        self.loop.at(self.loop.now+2000, self.release_ack, p, p.host_key, p.epoch)
        self.consume_host(p.channel)

    def release_ack(self, p, token, epoch):
        identity = (p.key, token, epoch)
        if identity in self.completion_seen or epoch != p.epoch or token != p.host_key:
            self.duplicate_completions += 1
            return
        self.completion_seen.add(identity)
        self.rx_out[p.channel].release(token)
        self.delivered_rx += p.content_length
        if self.high_at[p.channel] is not None and self.high_recovery_release[p.channel] is None:
            self.high_recovery_release[p.channel] = self.loop.now
            self.rx_state[p.channel] = "RECOVERING"
        self.release_board(p, "HOST_RELEASE_ACK")
        ch = p.channel
        if self.resume_at[ch] is not None and self.first_release_after_resume[ch] is None:
            self.first_release_after_resume[ch] = self.loop.now
        self.pump_rx(ch)

    def consume_host(self, ch):
        if not self.consumer_on[ch]:
            return
        while self.host_ready[ch]:
            p = self.host_ready[ch].popleft()
            self.host_ring[ch].release(p.host_key)
            self.event("HOST_CONSUMED", p)
        self.pump_rx(ch)

    def set_host(self, ch, enabled):
        self.host_on[ch] = enabled
        self.event("HOST_SERVICE_ON" if enabled else "HOST_SERVICE_OFF", channel=ch)
        if enabled:
            self.resume_at[ch] = self.loop.now
            self.pump_rx(ch)
        # Already accepted reads/transfers drain. Stopping credits cannot erase them.

    def release_board(self, p, cause):
        arena = (self.tx if p.direction == "TX" else self.rx)[p.channel]
        arena.release(p.key)
        if p.direction == "RX":
            self.observe_rx(p.channel)
        self.descriptors[p.channel+(0 if p.direction == "TX" else 2)].release(p.key)
        p.state, p.terminal_ns = "RELEASED", self.loop.now
        self.event(cause, p)

    def cancel(self, p):
        self.event("CANCEL_REQUEST", p, state=p.state)
        if p.state == "RESERVED":
            # Both software endpoints confirm the offer was never accepted.
            p.cancel_pending = True
            self.upload_credit[p.channel].release(p.key)
            self.cancel_tx_done(p)
            return "REVOKE_ACK_NO_ACCEPT"
        if p.direction == "TX" and p.state in ("UPLOAD_ACCEPTED", "WRITE_PENDING"):
            p.cancel_pending = True
            if p.state == "WRITE_PENDING":
                self.arb.cancel(p.work)
            return "DRAIN_ACCEPTED"
        if p.direction == "RX" and p.state in ("RX_READ_PENDING", "DOWNLOAD_ACCEPTED"):
            p.cancel_pending = True
            if p.state == "RX_READ_PENDING":
                self.arb.cancel(p.work)
            return "DRAIN_PULL_KEEP_BOARD_OBJECT"
        return "TOO_LATE_OR_TERMINAL"  # normal published/serialized Tx is atomic

    def cancel_tx_done(self, p):
        ch = p.channel
        if p.key in self.tx_stage[ch].tokens:
            self.tx_stage[ch].release(p.key)
        self.release_board(p, "TX_CANCEL_COMPLETED")
        self.cancel_results.append(dict(object=p.key, kind="TX", completed_prefix=p.work.completed if p.work else 0, time_ns=self.loop.now))

    def cancel_pull_done(self, p):
        ch = p.channel
        self.host_ring[ch].release(p.host_key)
        self.rx_out[ch].release(p.host_key)
        self.cancel_results.append(dict(object=p.key, kind="RX_RETRYABLE", completed_prefix=p.work.completed, time_ns=self.loop.now))
        p.cancel_pending, p.state = False, "PUBLISHED"
        self.event("PULL_CANCEL_COMPLETED_BOARD_RETAINED", p)
        self.rx_waiting[ch].append(p)
        # Retry requires a new explicit pump/recovery event and a fresh token.

    def run(self, end):
        self.arb.start(end)
        for ch in range(2):
            self.loop.at(0, self.air_tick, ch, end)
        self.loop.run(end)

    def report(self):
        pools = [a.credit for a in self.tx+self.rx]
        for group in (self.tx_stage, self.rx_stage, self.tx_fifo, self.rx_out, self.upload_credit, self.host_ring, self.descriptors):
            pools.extend(group)
        for arena in self.tx+self.rx:
            arena.check()
        rx_live = sum(p.content_length for p in self.packets.values() if p.direction == "RX" and p.state != "RELEASED")
        assert self.offered_rx == self.delivered_rx+self.dropped_rx+rx_live
        return dict(client_metrics=self.arb.metrics(), destination_metrics=self.arb.destination_metrics(), credits={p.name:p.report() for p in pools},
                    offered_rx_bytes=self.offered_rx, delivered_rx_bytes=self.delivered_rx,
                    dropped_rx_bytes=self.dropped_rx, retained_rx_bytes=rx_live,
                    rf_conservation_error=self.offered_rx-self.delivered_rx-self.dropped_rx-rx_live,
                    tx_rejected_attempt_bytes_including_retries=self.rejected_tx, tx_consumed_bytes=self.consumed_tx,
                    first_board_release_after_resume_ns=self.first_release_after_resume,
                    resume_ns=self.resume_at,
                    cancellation_results=self.cancel_results, duplicate_or_old_completions=self.duplicate_completions,
                    memory=dict(writes=self.memory.write_bytes, reads=self.memory.read_bytes, compare_operations=self.memory.compares),
                    calendar_misses=len(self.arb.slot_misses), service_faulted=self.service_faulted, packet_count=len(self.packets),
                    rx_state=self.rx_state, recovery_deadline_misses=self.recovery_deadline_misses,
                    pending_event_count=len(self.loop.events))
