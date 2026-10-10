"""Independent completion-event service-curve checker from the source model."""
from queue_service import T

def service_check(completions, quota, start, end):
    """Exact all-interval check of S(b)-S(a)>=R*(b-a-T) in one eligible busy span.

    S is right-continuous, integer completion bytes. Maxima occur just after
    completions, minima just before completions/end. Multiplication by T avoids
    floating rounding. This checker NEVER supplies events to the implementation.
    """
    total, max_f, worst = 0, -quota*start, 0
    for t, n in completions:
        if not start <= t <= end:
            continue
        before = total*T-quota*t
        worst = max(worst, max_f-before)
        total += n
        max_f = max(max_f, total*T-quota*t)
    worst = max(worst, max_f-(total*T-quota*end))
    return dict(interval_start_ns=start, interval_end_ns=end, completed_bytes=total,
                required_latency_ns=worst/quota, adopted_latency_ns=T,
                all_event_intervals_satisfy=worst <= quota*T)
