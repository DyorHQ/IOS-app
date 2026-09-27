import { getAddress, isAddress, type Address, type Hex } from "viem";

/* Recipient checks for the Send sheet. A transfer can't be undone, so the destinations that lose the tokens for
   certain are refused outright (the zero address, the token's own contract), and the ones that may lose them are
   flagged: a contract recipient needs the sender's explicit confirmation, and sending to one's own wallet is noted.
   A recipient whose bytecode is not known yet (still being read, or the read failed) is never cleared. */

export type RecipientCheck = { block: string | null; warn: string | null; contract: boolean; wait: string | null };

const ZERO = "0x0000000000000000000000000000000000000000";

/** The `code` for a recipient whose bytecode read failed: it may be a contract, so Send waits for a read that answers. */
export const CODE_UNREADABLE = "unreadable";

/** EIP-7702 delegation code (0xef0100 followed by the delegate's address): an externally owned account that delegates
    to a contract. Many Monad wallets carry it; it is not a contract recipient. */
export const isDelegatedAccount = (code: Hex) => /^0xef0100[0-9a-fA-F]{40}$/.test(code);

/** `code` is the recipient's bytecode (undefined or "0x" for none), null while it is being read, or CODE_UNREADABLE when
    the read failed. `wait` is set while the bytecode is unknown: why Send must wait. */
export function checkRecipient(to: string, token: { address: Address; symbol: string; native?: boolean }, sender: Address | null, code: Hex | undefined | null | typeof CODE_UNREADABLE): RecipientCheck {
  const input = to.trim();
  if (!isAddress(input)) return { block: "Enter a valid address (0x and 40 hex characters, checksum intact).", warn: null, contract: false, wait: null };
  const address = getAddress(input);
  if (address === ZERO) return { block: "That is the zero address. Anything sent there is burned.", warn: null, contract: false, wait: null };
  if (!token.native && address === getAddress(token.address)) return { block: `That is the ${token.symbol} token contract itself. Tokens sent to it are lost.`, warn: null, contract: false, wait: null };
  if (code === null) return { block: null, warn: null, contract: false, wait: "Checking the address…" };
  if (code === CODE_UNREADABLE) return { block: null, warn: null, contract: false, wait: "Couldn't check whether this address is a contract. Retrying…" };
  if (code && code !== "0x" && !isDelegatedAccount(code)) {
    return { block: null, warn: `That address is a contract. A contract that is not built to receive ${token.symbol} can't send it back, so only continue if you know this one does.`, contract: true, wait: null };
  }
  if (sender && address === getAddress(sender)) return { block: null, warn: "That is your own wallet: the transfer only costs gas.", contract: false, wait: null };
  return { block: null, warn: null, contract: false, wait: null };
}
