package app_test

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"testing"

	transfertypes "github.com/cosmos/ibc-go/v10/modules/apps/transfer/types"
	clienttypes "github.com/cosmos/ibc-go/v10/modules/core/02-client/types"
	channeltypes "github.com/cosmos/ibc-go/v10/modules/core/04-channel/types"
	porttypes "github.com/cosmos/ibc-go/v10/modules/core/05-port/types"
	ibcexported "github.com/cosmos/ibc-go/v10/modules/core/exported"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	sdk "github.com/cosmos/cosmos-sdk/types"

	"github.com/CosmWasm/wasmd/x/wasm"
)

// mockIBCModule captures packet data seen on OnRecvPacket and satisfies
// callbacks.CallbacksCompatibleModule (IBCModule + PacketDataUnmarshaler)
// so it can be passed to NewIBCV1CallbacksPlusMiddleware.
type mockIBCModule struct {
	porttypes.IBCModule
	received []byte
}

func (m *mockIBCModule) OnRecvPacket(_ sdk.Context, _ string, packet channeltypes.Packet, _ sdk.AccAddress) ibcexported.Acknowledgement {
	m.received = packet.Data
	return channeltypes.NewResultAcknowledgement([]byte("ok"))
}

func (m *mockIBCModule) UnmarshalPacketData(_ sdk.Context, _, _ string, _ []byte) (any, string, error) {
	return nil, "", nil
}

// mockICS4Wrapper captures SendPacket data.
type mockICS4Wrapper struct {
	porttypes.ICS4Wrapper
	sentData []byte
}

func (m *mockICS4Wrapper) SendPacket(_ sdk.Context, _, _ string, _ clienttypes.Height, _ uint64, data []byte) (uint64, error) {
	m.sentData = data
	return 1, nil
}

func transferData(t *testing.T, memo string) []byte {
	t.Helper()
	data, err := json.Marshal(transfertypes.FungibleTokenPacketData{
		Denom:    "untrn",
		Amount:   "1",
		Sender:   "neutron1sender",
		Receiver: "neutron1receiver",
		Memo:     memo,
	})
	require.NoError(t, err)
	return data
}

// --- IBCV1CallbacksPlusMiddleware (recv-side rewriter) ---

// dest_callback.calldata rewrites Receiver to the Hooks-style intermediate so
// transfer credits the intermediate that IBCReceivePacketCallback later uses.
func TestCallbacksPlusMiddleware_RewritesReceiverOnDestCalldata(t *testing.T) {
	inner := &mockIBCModule{}
	mw := wasm.NewIBCV1CallbacksPlusMiddleware(inner)

	calldataHex := hex.EncodeToString([]byte(`{"do":{}}`))
	memo := fmt.Sprintf(`{"dest_callback":{"address":"neutron1contract","calldata":%q}}`, calldataHex)
	pkt := channeltypes.Packet{
		Data:               transferData(t, memo),
		SourcePort:         "transfer",
		SourceChannel:      "channel-0",
		DestinationPort:    "transfer",
		DestinationChannel: "channel-1",
	}
	mw.OnRecvPacket(sdk.Context{}, "ics20-1", pkt, sdk.AccAddress{})

	require.NotNil(t, inner.received)
	var got transfertypes.FungibleTokenPacketData
	require.NoError(t, json.Unmarshal(inner.received, &got))

	expectedIntermediate, err := wasm.DeriveIntermediateSender(
		"channel-1", "neutron1sender", sdk.GetConfig().GetBech32AccountAddrPrefix(),
	)
	require.NoError(t, err)
	assert.Equal(t, expectedIntermediate, got.Receiver, "Receiver must be the Hooks intermediate")
	assert.Equal(t, "neutron1sender", got.Sender, "Sender must be preserved")
	assert.Equal(t, memo, got.Memo, "Memo must be preserved")
}

// Without dest_callback.calldata the middleware is a no-op pass-through.
func TestCallbacksPlusMiddleware_LeavesPacketWhenNoCalldata(t *testing.T) {
	specs := map[string]string{
		"empty memo":                     "",
		"hooks only":                     `{"wasm":{"contract":"neutron1c","msg":{}}}`,
		"dest_callback without calldata": `{"dest_callback":{"address":"neutron1c"}}`,
	}
	for name, memo := range specs {
		t.Run(name, func(t *testing.T) {
			inner := &mockIBCModule{}
			mw := wasm.NewIBCV1CallbacksPlusMiddleware(inner)

			pkt := channeltypes.Packet{
				Data:               transferData(t, memo),
				SourcePort:         "transfer",
				SourceChannel:      "channel-0",
				DestinationPort:    "transfer",
				DestinationChannel: "channel-1",
			}
			mw.OnRecvPacket(sdk.Context{}, "ics20-1", pkt, sdk.AccAddress{})
			assert.Equal(t, pkt.Data, inner.received, "packet must be forwarded byte-for-byte")
		})
	}
}

// --- IBCDedupMiddleware ---

// Recv: wasm + dest_callback is a same-side (destination) collision; dedup
// rejects with an error acknowledgement and the inner stack is not invoked.
func TestDedup_RecvRejectsWasmDestCallbackCollision(t *testing.T) {
	inner := &mockIBCModule{}
	mw := wasm.NewIBCDedupMiddleware(inner, &mockICS4Wrapper{})

	memo := `{"wasm":{"contract":"neutron1c","msg":{}},"dest_callback":{"address":"neutron1c"}}`
	pkt := channeltypes.Packet{Data: transferData(t, memo), SourcePort: "transfer", SourceChannel: "channel-0"}
	ack := mw.OnRecvPacket(sdk.Context{}, "ics20-1", pkt, sdk.AccAddress{})

	require.NotNil(t, ack)
	assert.False(t, ack.Success(), "same-side wasm+dest_callback must yield an error ack")
	assert.Nil(t, inner.received, "rejected packets must not reach the inner stack")
}

// Cross-side combinations and isolated callback keys pass through byte-for-byte;
// nothing is stripped or rewritten by dedup.
func TestDedup_RecvPassesThrough(t *testing.T) {
	specs := map[string]string{
		"wasm + src_callback (cross-side)":          `{"wasm":{"contract":"neutron1c","msg":{}},"src_callback":{"address":"neutron1c"}}`,
		"ibc_callback + dest_callback (cross-side)": `{"ibc_callback":"neutron1c","dest_callback":{"address":"neutron1c"}}`,
		"wasm alone":          `{"wasm":{"contract":"neutron1c","msg":{}}}`,
		"dest_callback alone": `{"dest_callback":{"address":"neutron1c"}}`,
	}
	for name, memo := range specs {
		t.Run(name, func(t *testing.T) {
			inner := &mockIBCModule{}
			mw := wasm.NewIBCDedupMiddleware(inner, &mockICS4Wrapper{})

			pkt := channeltypes.Packet{Data: transferData(t, memo), SourcePort: "transfer", SourceChannel: "channel-0"}
			ack := mw.OnRecvPacket(sdk.Context{}, "ics20-1", pkt, sdk.AccAddress{})

			require.NotNil(t, ack)
			assert.True(t, ack.Success())
			assert.Equal(t, pkt.Data, inner.received, "packet must be forwarded byte-for-byte")
		})
	}
}

// Send: ibc_callback + src_callback is a same-side (source) collision; dedup
// rejects at SendPacket time and the channel keeper does not see the packet.
func TestDedup_SendRejectsIbcCallbackSrcCallbackCollision(t *testing.T) {
	inner := &mockICS4Wrapper{}
	mw := wasm.NewIBCDedupMiddleware(&mockIBCModule{}, inner)

	data := transferData(t, `{"ibc_callback":"neutron1c","src_callback":{"address":"neutron1c"}}`)
	_, err := mw.SendPacket(sdk.Context{}, "transfer", "channel-0", clienttypes.NewHeight(0, 100), 0, data)

	require.Error(t, err)
	assert.Nil(t, inner.sentData, "rejected packets must not reach the channel keeper")
}

func TestDedup_SendPassesThrough(t *testing.T) {
	specs := map[string]string{
		"ibc_callback + dest_callback (cross-side)": `{"ibc_callback":"neutron1c","dest_callback":{"address":"neutron1c"}}`,
		"wasm + src_callback (cross-side)":          `{"wasm":{"contract":"neutron1c","msg":{}},"src_callback":{"address":"neutron1c"}}`,
		"src_callback alone":                        `{"src_callback":{"address":"neutron1c"}}`,
		"ibc_callback alone":                        `{"ibc_callback":"neutron1c"}`,
	}
	for name, memo := range specs {
		t.Run(name, func(t *testing.T) {
			inner := &mockICS4Wrapper{}
			mw := wasm.NewIBCDedupMiddleware(&mockIBCModule{}, inner)

			data := transferData(t, memo)
			_, err := mw.SendPacket(sdk.Context{}, "transfer", "channel-0", clienttypes.NewHeight(0, 100), 0, data)

			require.NoError(t, err)
			assert.Equal(t, data, inner.sentData, "packet data must be forwarded byte-for-byte")
		})
	}
}
