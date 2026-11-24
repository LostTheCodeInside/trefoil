// Not upstream. The counters gVisor already keeps, so a claim about where packets go
// can be a number rather than a theory.
package netstack

import "fmt"

// Stats reports the tunnel's TCP and NIC counters as one line.
func (net *Net) Stats() string {
	s := net.stack.Stats()
	nic := net.stack.NICInfo()[1].Stats
	return fmt.Sprintf(
		"tcp: sent=%d valid=%d invalid=%d resent=%d slowStartResent=%d fastRetrans=%d "+
			"timeouts=%d fastRecov=%d sackRecov=%d sendErr=%d badCksum=%d | "+
			"nic: tx=%d txDropNoBuf=%d rx=%d",
		s.TCP.SegmentsSent.Value(), s.TCP.ValidSegmentsReceived.Value(),
		s.TCP.InvalidSegmentsReceived.Value(), s.TCP.Retransmits.Value(),
		s.TCP.SlowStartRetransmits.Value(), s.TCP.FastRetransmit.Value(),
		s.TCP.Timeouts.Value(), s.TCP.FastRecovery.Value(), s.TCP.SACKRecovery.Value(),
		s.TCP.SegmentSendErrors.Value(), s.TCP.ChecksumErrors.Value(),
		nic.Tx.Packets.Value(), nic.TxPacketsDroppedNoBufferSpace.Value(),
		nic.Rx.Packets.Value(),
	)
}
