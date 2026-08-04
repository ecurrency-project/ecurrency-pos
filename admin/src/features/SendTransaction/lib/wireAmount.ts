/**
 * Base-unit amount as it goes on the wire: a decimal string.
 *
 * The node validates a native output value with `^[0-9]+$` and takes it as
 * satoshi (Utils.pm::create_txo), so a digit string is accepted as-is, keeps
 * values above 2^53 exact and never turns into exponent notation the way
 * JSON.stringify would. BigInt has no JSON representation anyway.
 */
export const toWireAmount = (sat: bigint): string => sat.toString();
