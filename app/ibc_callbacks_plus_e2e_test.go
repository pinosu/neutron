package app_test

import (
	"encoding/hex"
	"fmt"
	"os"
	"testing"
	"time"

	sdkmath "cosmossdk.io/math"
	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
	abci "github.com/cometbft/cometbft/abci/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	transfertypes "github.com/cosmos/ibc-go/v10/modules/apps/transfer/types"
	clienttypes "github.com/cosmos/ibc-go/v10/modules/core/02-client/types"
	channeltypes "github.com/cosmos/ibc-go/v10/modules/core/04-channel/types"
	ibctesting "github.com/cosmos/ibc-go/v10/testing"
	"github.com/stretchr/testify/suite"

	appparams "github.com/neutron-org/neutron/v11/app/params"
	"github.com/neutron-org/neutron/v11/testutil"
)

type IBCCallbacksPlusE2ESuite struct {
	testutil.IBCConnectionTestSuite
}

func TestIBCCallbacksPlusE2E(t *testing.T) {
	suite.Run(t, new(IBCCallbacksPlusE2ESuite))
}

const transferAmount = 1000

// transferMsg builds an A->B transfer of transferAmount with the given receiver and memo.
func (s *IBCCallbacksPlusE2ESuite) transferMsg(receiver, memo string) sdk.Msg {
	return transfertypes.NewMsgTransfer(
		s.TransferPath.EndpointA.ChannelConfig.PortID,
		s.TransferPath.EndpointA.ChannelID,
		sdk.NewCoin(appparams.DefaultDenom, sdkmath.NewInt(transferAmount)),
		s.ChainA.SenderAccount.GetAddress().String(),
		receiver,
		clienttypes.NewHeight(10, 100),
		uint64(time.Now().UnixNano()), //nolint:gosec
		memo,
	)
}

// relayRecv sends msg on A, relays the packet to B and returns the packet and B's recv result.
func (s *IBCCallbacksPlusE2ESuite) relayRecv(msg sdk.Msg) (channeltypes.Packet, *abci.ExecTxResult) {
	sendResult, err := s.SendMsgsNoCheck(s.ChainA, msg)
	s.Require().NoError(err)

	packet, err := ibctesting.ParsePacketFromEvents(sendResult.GetEvents()) //nolint:staticcheck
	s.Require().NoError(err)
	s.Require().NoError(s.TransferPath.EndpointB.UpdateClient())
	recvResult, err := s.TransferPath.EndpointB.RecvPacketWithResult(packet)
	s.Require().NoError(err)
	return packet, recvResult
}

// ackBack parses B's ack and acknowledges it on A, returning A's ack result.
func (s *IBCCallbacksPlusE2ESuite) ackBack(packet channeltypes.Packet, recvResult *abci.ExecTxResult) (*abci.ExecTxResult, []byte) {
	ack, err := ibctesting.ParseAckFromEvents(recvResult.GetEvents())
	s.Require().NoError(err)
	s.Require().NoError(s.TransferPath.EndpointA.UpdateClient())
	ackResult, err := s.TransferPath.EndpointA.AcknowledgePacketWithResult(packet, ack)
	s.Require().NoError(err)
	return ackResult, ack
}

// deployReflect stores and instantiates reflect.wasm on the given chain.
func (s *IBCCallbacksPlusE2ESuite) deployReflect(chain *ibctesting.TestChain) string {
	app := s.GetNeutronZoneApp(chain)
	owner := chain.SenderAccount.GetAddress()
	wasmCode, err := os.ReadFile("../wasmbinding/testdata/reflect.wasm") //nolint:gosec
	s.Require().NoError(err)

	permKeeper := wasmkeeper.NewDefaultPermissionKeeper(app.WasmKeeper)
	codeID, _, err := permKeeper.Create(chain.GetContext(), owner, wasmCode, &wasmtypes.AccessConfig{Permission: wasmtypes.AccessTypeEverybody})
	s.Require().NoError(err)
	addr, _, err := permKeeper.Instantiate(chain.GetContext(), codeID, owner, owner, []byte("{}"), "callbacks-plus-test", nil)
	s.Require().NoError(err)
	return addr.String()
}

// bondBalance returns addr's balance in the native bond denom (used for refunds
// on the source chain, which are denominated in the original denom).
func (s *IBCCallbacksPlusE2ESuite) bondBalance(chain *ibctesting.TestChain, addr string) sdkmath.Int {
	sdkAddr, err := sdk.AccAddressFromBech32(addr)
	s.Require().NoError(err)
	return s.GetNeutronZoneApp(chain).BankKeeper.GetBalance(chain.GetContext(), sdkAddr, appparams.DefaultDenom).Amount
}

// hasFunds reports whether addr holds any coins (a received IBC voucher is an
// ibc/<hash> denom, not the native bond denom).
func (s *IBCCallbacksPlusE2ESuite) hasFunds(chain *ibctesting.TestChain, addr string) bool {
	sdkAddr, err := sdk.AccAddressFromBech32(addr)
	s.Require().NoError(err)
	return !s.GetNeutronZoneApp(chain).BankKeeper.GetAllBalances(chain.GetContext(), sdkAddr).IsZero()
}

// callbackEvent returns the attributes of the first event of evType, if any.
func callbackEvent(events []abci.Event, evType string) (map[string]string, bool) {
	for _, ev := range events {
		if ev.Type != evType {
			continue
		}
		attrs := make(map[string]string, len(ev.Attributes))
		for _, a := range ev.Attributes {
			attrs[a.Key] = a.Value
		}
		return attrs, true
	}
	return nil, false
}

// Plain transfer with no memo round-trips to a success ack.
func (s *IBCCallbacksPlusE2ESuite) TestPlainTransferRoundTrip() {
	s.ConfigureTransferChannel()
	packet, recvResult := s.relayRecv(s.transferMsg(s.ChainB.SenderAccount.GetAddress().String(), ""))
	_, ack := s.ackBack(packet, recvResult)
	s.Require().Contains(string(ack), `"result"`)
}

// A wasm memo to a real reflect contract on B is dispatched by Hooks: the
// contract ends up holding the IBC voucher. Guards the existing Hooks recv path
// against the Callbacks+ recv wiring.
func (s *IBCCallbacksPlusE2ESuite) TestOnlyHooksDispatchesExecuteOnB() {
	s.ConfigureTransferChannel()
	contractAddr := s.deployReflect(s.ChainB)
	memo := fmt.Sprintf(`{"wasm":{"contract":%q,"msg":{"reflect_msg":{"msgs":[]}}}}`, contractAddr)

	packet, recvResult := s.relayRecv(s.transferMsg(contractAddr, memo))

	s.Require().True(s.hasFunds(s.ChainB, contractAddr),
		"Hooks must dispatch execute and credit the contract")
	s.ackBack(packet, recvResult)
}

// A dest_callback.calldata memo is dispatched via Execute: ibc_dest_callback
// succeeds and the contract holds the transferred funds.
func (s *IBCCallbacksPlusE2ESuite) TestDestCallbackCalldataDispatchesExecuteOnB() {
	s.ConfigureTransferChannel()
	contractAddr := s.deployReflect(s.ChainB)
	calldata := hex.EncodeToString([]byte(`{"reflect_msg":{"msgs":[]}}`))
	memo := fmt.Sprintf(`{"dest_callback":{"address":%q,"calldata":%q}}`, contractAddr, calldata)

	// Receiver is incidental: the Callbacks+ middleware rewrites it to the
	// Hooks-style intermediate on recv; the contract comes from dest_callback.address.
	_, recvResult := s.relayRecv(s.transferMsg(contractAddr, memo))

	attrs, found := callbackEvent(recvResult.GetEvents(), "ibc_dest_callback")
	s.Require().True(found, "ibc_dest_callback event must be emitted")
	s.Require().Equal("success", attrs["callback_result"])
	s.Require().Equal(contractAddr, attrs["callback_address"])
	s.Require().True(s.hasFunds(s.ChainB, contractAddr),
		"contract must hold the IBC voucher after Execute dispatch")
}

// A dest_callback without calldata routes to the ADR-008 ibc_destination_callback
// (sudo) dispatch, not Execute. reflect has no such handler, so it fails and the
// recv reverts to an error ack, refunding the sender.
func (s *IBCCallbacksPlusE2ESuite) TestDestCallbackNoCalldataFallback() {
	s.ConfigureTransferChannel()
	contractAddr := s.deployReflect(s.ChainB)
	memo := fmt.Sprintf(`{"dest_callback":{"address":%q}}`, contractAddr)

	sender := s.ChainA.SenderAccount.GetAddress().String()
	balBefore := s.bondBalance(s.ChainA, sender)

	packet, recvResult := s.relayRecv(s.transferMsg(s.ChainB.SenderAccount.GetAddress().String(), memo))

	s.Require().False(s.hasFunds(s.ChainB, contractAddr), "no-calldata path must not dispatch Execute")

	_, ack := s.ackBack(packet, recvResult)
	s.Require().Contains(string(ack), `"error"`, "failed dest callback must revert with an error ack")
	s.Require().Equal(balBefore, s.bondBalance(s.ChainA, sender), "reverted transfer must refund the sender")
}

// A dest_callback.calldata whose Execute fails reverts the transfer: the recv
// becomes an error ack, refunding the sender, and the contract holds nothing.
func (s *IBCCallbacksPlusE2ESuite) TestDestCallbackCalldataExecuteFailureRefund() {
	s.ConfigureTransferChannel()
	contractAddr := s.deployReflect(s.ChainB)
	calldata := hex.EncodeToString([]byte(`{"definitely_unknown_variant":{}}`))
	memo := fmt.Sprintf(`{"dest_callback":{"address":%q,"calldata":%q}}`, contractAddr, calldata)

	sender := s.ChainA.SenderAccount.GetAddress().String()
	balBefore := s.bondBalance(s.ChainA, sender)

	packet, recvResult := s.relayRecv(s.transferMsg(contractAddr, memo))

	s.Require().False(s.hasFunds(s.ChainB, contractAddr), "failed Execute must not credit the contract")

	_, ack := s.ackBack(packet, recvResult)
	s.Require().Contains(string(ack), `"error"`, "failed Execute must revert with an error ack")
	s.Require().Equal(balBefore, s.bondBalance(s.ChainA, sender), "reverted transfer must refund the sender")
}

// A src_callback whose address is the packet sender (ADR-008 self-registration,
// enforced at send) fires ibc_source_callback on ack. The sender is an EOA, so
// the dispatch fails, but the event still fires — which is the wiring under test.
func (s *IBCCallbacksPlusE2ESuite) TestSrcCallbackFiresIBCSourceCallbackOnAck() {
	s.ConfigureTransferChannel()
	sender := s.ChainA.SenderAccount.GetAddress().String()
	memo := fmt.Sprintf(`{"src_callback":{"address":%q}}`, sender)

	packet, recvResult := s.relayRecv(s.transferMsg(s.ChainB.SenderAccount.GetAddress().String(), memo))
	ackResult, _ := s.ackBack(packet, recvResult)

	attrs, found := callbackEvent(ackResult.GetEvents(), "ibc_src_callback")
	s.Require().True(found, "ibc_src_callback event must be emitted on ack")
	s.Require().Equal(sender, attrs["callback_address"])
	s.Require().Equal("acknowledgement_packet", attrs["callback_type"])
	s.Require().Contains([]string{"success", "failure"}, attrs["callback_result"])
}

// A src_callback carrying calldata is rejected at send by IBCSendPacketCallback
// (the callbacks middleware on the keeper's send-side wrapper).
func (s *IBCCallbacksPlusE2ESuite) TestSrcCallbackCalldataSendRejected() {
	s.ConfigureTransferChannel()
	calldata := hex.EncodeToString([]byte(`{"reflect_msg":{"msgs":[]}}`))
	memo := fmt.Sprintf(`{"src_callback":{"address":%q,"calldata":%q}}`, s.ChainA.SenderAccount.GetAddress().String(), calldata)

	result, err := s.SendMsgsNoCheck(s.ChainA, s.transferMsg(s.ChainB.SenderAccount.GetAddress().String(), memo))
	s.Require().Error(err)
	s.Require().NotNil(result)
	s.Require().NotEqual(uint32(0), result.Code)
	s.Require().Contains(err.Error(), "src_callback must not contain a calldata field")
}

// ibc_callback + src_callback is a same-side (source) collision rejected at send
// time by Dedup; the packet never leaves A.
func (s *IBCCallbacksPlusE2ESuite) TestHooksAndSrcCallbackSendRejected() {
	s.ConfigureTransferChannel()
	memo := `{"ibc_callback":"neutron1foo","src_callback":{"address":"neutron1foo"}}`

	result, err := s.SendMsgsNoCheck(s.ChainA, s.transferMsg(s.ChainB.SenderAccount.GetAddress().String(), memo))
	s.Require().Error(err)
	s.Require().NotNil(result)
	s.Require().NotEqual(uint32(0), result.Code)
	s.Require().Contains(err.Error(), "memo must not contain both ibc_callback")
}

// wasm + dest_callback is a same-side (destination) collision rejected by Dedup
// on recv with an error ack; the transfer reverts on the source chain.
func (s *IBCCallbacksPlusE2ESuite) TestHooksAndDestCallbackRecvRejected() {
	s.ConfigureTransferChannel()
	memo := `{"wasm":{"contract":"neutron1foo","msg":{"x":1}},"dest_callback":{"address":"neutron1foo","calldata":"deadbeef"}}`

	packet, recvResult := s.relayRecv(s.transferMsg(s.ChainB.SenderAccount.GetAddress().String(), memo))
	_, ack := s.ackBack(packet, recvResult)
	s.Require().Contains(string(ack), `"error"`, "dedup must produce an error acknowledgement")
}

// A single packet carrying wasm (Hooks-recv) and src_callback (Callbacks-src) is
// a cross-side combo: Dedup passes it, Hooks dispatches on B on recv, and the
// callbacks middleware fires the source callback on A on ack. src_callback.address
// is the packet sender (ADR-008 self-registration enforced at send).
func (s *IBCCallbacksPlusE2ESuite) TestCrossSideComboHooksRecvAndSrcCallbackOnAck() {
	s.ConfigureTransferChannel()
	reflectOnB := s.deployReflect(s.ChainB)
	sender := s.ChainA.SenderAccount.GetAddress().String()
	memo := fmt.Sprintf(
		`{"wasm":{"contract":%q,"msg":{"reflect_msg":{"msgs":[]}}},"src_callback":{"address":%q}}`,
		reflectOnB, sender,
	)

	packet, recvResult := s.relayRecv(s.transferMsg(reflectOnB, memo))

	s.Require().True(s.hasFunds(s.ChainB, reflectOnB),
		"Hooks must dispatch on recv (contract on B holds the IBC voucher)")

	ackResult, _ := s.ackBack(packet, recvResult)
	attrs, found := callbackEvent(ackResult.GetEvents(), "ibc_src_callback")
	s.Require().True(found, "ibc_src_callback must fire on ack for the cross-side combo")
	s.Require().Equal(sender, attrs["callback_address"])
	s.Require().Contains([]string{"success", "failure"}, attrs["callback_result"])
}
