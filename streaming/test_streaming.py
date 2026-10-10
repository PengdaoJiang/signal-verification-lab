import unittest
from queue_service import Arena,Credit,Memory,VOQ,Work,subspans
from service_check import service_check

class StreamingTests(unittest.TestCase):
    def test_credit_conservation_and_double_release(self):
        c=Credit('test',64);c.reserve('a',20);c.reserve('b',40)
        self.assertFalse(c.fits(5));c.release('a');c.release('b')
        self.assertEqual(c.report()['conservation_error'],0)
        with self.assertRaises(KeyError):c.release('b')
    def test_fragmented_byte_exact_transfer(self):
        a=Arena('synthetic',0,16384);a.reserve('first',4000)
        spans=a.reserve('payload',5000);parts=subspans(spans,0,5000)
        self.assertTrue(all(x//4096==(x+n-1)//4096 for x,n in parts))
        mem=Memory();payload=bytes(i%251 for i in range(5000))
        mem.write(parts,payload);self.assertEqual(mem.read(parts),payload)
        a.release('first');a.release('payload');a.check();self.assertEqual(a.free,[(0,16384)])
    def test_blocked_destination_does_not_block_other(self):
        q=VOQ(quantum=8)
        blocked=Work('a',0,16,[],b'x'*16,0,destination='blocked',gate=lambda:False)
        ready=Work('b',0,16,[],b'y'*16,0,destination='ready')
        q.put(blocked);q.put(ready);pieces=q.take(16,0)
        self.assertEqual(sum(n for _,_,n in pieces),16)
        self.assertTrue(all(w is ready for w,_,_ in pieces));self.assertEqual(blocked.cursor,0)
    def test_checker_uses_completed_events_not_requested_bytes(self):
        self.assertFalse(service_check([],4096,0,300000)['all_event_intervals_satisfy'])
        self.assertTrue(service_check([(100000,4096),(200000,4096),(300000,4096)],4096,0,300000)['all_event_intervals_satisfy'])

if __name__=='__main__':unittest.main()
