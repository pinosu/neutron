use cosmwasm_schema::cw_serde;
use cosmwasm_std::{
    entry_point, to_json_binary, to_json_string, Binary, Deps, DepsMut, Empty, Env,
    IbcBasicResponse, IbcCallbackRequest, IbcDestinationCallbackMsg, IbcDstCallback,
    IbcMsg, IbcSourceCallbackMsg, IbcSrcCallback, MessageInfo, Response, StdError, StdResult,
};
use cw_storage_plus::{Item, Map};

const CALLS: Map<u64, Call> = Map::new("calls");
const N: Item<u64> = Item::new("n");
const STATS: Item<Stats> = Item::new("stats");

#[cw_serde]
struct Call {
    sender: String,
    funds: String,
    msg: String,
}

#[cw_serde]
#[derive(Default)]
struct Stats {
    dest: u32,
    ack: u32,
    timeout: u32,
    lifecycle: u32,
}

#[cw_serde]
pub enum ExecuteMsg {
    Record {},
    Fail {},
    Transfer {
        to_address: String,
        channel_id: String,
        memo: Option<String>,
        /// Optional timeout in seconds; defaults to 600 when absent.
        timeout_seconds: Option<u64>,
    },
}

#[cw_serde]
pub enum QueryMsg {
    Calls {},
    Stats {},
}

#[cw_serde]
pub struct CallsResp {
    pub calls: Vec<CallOut>,
}

#[cw_serde]
pub struct CallOut {
    pub sender: String,
    pub funds: String,
    pub msg: String,
}

#[entry_point]
pub fn instantiate(deps: DepsMut, _e: Env, _i: MessageInfo, _m: Empty) -> StdResult<Response> {
    N.save(deps.storage, &0)?;
    STATS.save(deps.storage, &Stats::default())?;
    Ok(Response::new())
}

fn push(deps: DepsMut, sender: &str, funds_str: &str, msg: &str) -> StdResult<()> {
    let i = N.load(deps.storage)? + 1;
    N.save(deps.storage, &i)?;
    CALLS.save(
        deps.storage,
        i,
        &Call {
            sender: sender.to_string(),
            funds: funds_str.to_string(),
            msg: msg.into(),
        },
    )
}

#[entry_point]
pub fn execute(
    deps: DepsMut,
    env: Env,
    info: MessageInfo,
    msg: ExecuteMsg,
) -> StdResult<Response> {
    let funds_str = info
        .funds
        .iter()
        .map(|c| c.to_string())
        .collect::<Vec<_>>()
        .join(",");
    match msg {
        ExecuteMsg::Record {} => {
            push(deps, info.sender.as_str(), &funds_str, "record")?;
            Ok(Response::new())
        }
        ExecuteMsg::Fail {} => Err(StdError::msg("intentional failure")),
        ExecuteMsg::Transfer {
            to_address,
            channel_id,
            memo,
            timeout_seconds,
        } => {
            push(deps, info.sender.as_str(), &funds_str, "transfer")?;
            let mut r = Response::new();
            if !info.funds.is_empty() {
                // Build the memo: if caller passed one use it, otherwise build src+dst callback memo
                let ibc_memo = if let Some(m) = memo {
                    Some(m)
                } else {
                    let cb = IbcCallbackRequest::both(
                        IbcSrcCallback {
                            address: env.contract.address.clone(),
                            gas_limit: None,
                        },
                        IbcDstCallback {
                            address: env.contract.address.to_string(),
                            gas_limit: None,
                        },
                    );
                    Some(to_json_string(&cb).map_err(|e| StdError::msg(e.to_string()))?)
                };
                let timeout_secs = timeout_seconds.unwrap_or(600);
                r = r.add_message(IbcMsg::Transfer {
                    channel_id,
                    to_address,
                    amount: info.funds[0].clone(),
                    timeout: env.block.time.plus_seconds(timeout_secs).into(),
                    memo: ibc_memo,
                });
            }
            Ok(r)
        }
    }
}

fn bump(deps: DepsMut, f: impl Fn(&mut Stats)) -> StdResult<IbcBasicResponse> {
    let mut s = STATS.load(deps.storage)?;
    f(&mut s);
    STATS.save(deps.storage, &s)?;
    Ok(IbcBasicResponse::new())
}

#[entry_point]
pub fn ibc_destination_callback(
    deps: DepsMut,
    _env: Env,
    _msg: IbcDestinationCallbackMsg,
) -> StdResult<IbcBasicResponse> {
    bump(deps, |s| s.dest += 1)
}

#[entry_point]
pub fn ibc_source_callback(
    deps: DepsMut,
    _env: Env,
    msg: IbcSourceCallbackMsg,
) -> StdResult<IbcBasicResponse> {
    match msg {
        IbcSourceCallbackMsg::Acknowledgement(_) => bump(deps, |s| s.ack += 1),
        IbcSourceCallbackMsg::Timeout(_) => bump(deps, |s| s.timeout += 1),
    }
}

#[entry_point]
pub fn sudo(deps: DepsMut, _env: Env, msg: serde_json::Value) -> StdResult<Response> {
    // ibc_lifecycle_complete: standard IBC Hooks source lifecycle (wasmd)
    // response / error: neutron Transfer module fires sudo on the contract sender after ack
    if msg.get("ibc_lifecycle_complete").is_some()
        || msg.get("response").is_some()
        || msg.get("error").is_some()
    {
        let mut s = STATS.load(deps.storage)?;
        s.lifecycle += 1;
        STATS.save(deps.storage, &s)?;
    }
    Ok(Response::new())
}

#[entry_point]
pub fn query(deps: Deps, _e: Env, msg: QueryMsg) -> StdResult<Binary> {
    match msg {
        QueryMsg::Calls {} => {
            let calls = CALLS
                .range(deps.storage, None, None, cosmwasm_std::Order::Ascending)
                .map(|r| {
                    r.map(|(_, c)| CallOut {
                        sender: c.sender,
                        funds: c.funds,
                        msg: c.msg,
                    })
                })
                .collect::<StdResult<Vec<_>>>()?;
            to_json_binary(&CallsResp { calls })
        }
        QueryMsg::Stats {} => to_json_binary(&STATS.load(deps.storage)?),
    }
}
