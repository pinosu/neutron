package app

import (
	errorsmod "cosmossdk.io/errors"
	sdk "github.com/cosmos/cosmos-sdk/types"

	transfertypes "github.com/cosmos/ibc-go/v10/modules/apps/transfer/types"
	porttypes "github.com/cosmos/ibc-go/v10/modules/core/05-port/types"
	ibcerrors "github.com/cosmos/ibc-go/v10/modules/core/errors"
)

// packetDataUnmarshalerAdapter wraps an IBCModule so that it satisfies
// callbackstypes.CallbacksCompatibleModule. Neutron's transfer stack
// (hooks/rate-limit/PFM) does not forward UnmarshalPacketData, so we provide it
// here by looking up the channel version via the supplied ICS4Wrapper and
// parsing as transfer packet data.
type packetDataUnmarshalerAdapter struct {
	porttypes.IBCModule
	ics4Wrapper porttypes.ICS4Wrapper
}

var _ porttypes.PacketDataUnmarshaler = packetDataUnmarshalerAdapter{}

func (a packetDataUnmarshalerAdapter) UnmarshalPacketData(ctx sdk.Context, portID, channelID string, bz []byte) (any, string, error) {
	version, found := a.ics4Wrapper.GetAppVersion(ctx, portID, channelID)
	if !found {
		return nil, "", errorsmod.Wrapf(ibcerrors.ErrNotFound, "app version not found for port %s and channel %s", portID, channelID)
	}
	ftpd, err := transfertypes.UnmarshalPacketData(bz, version, "")
	return ftpd, version, err
}
