import { getAddress, isAddress, type Address, type Hex } from "viem";

/* Recipient checks for the Send sheet. A transfer can't be undone, so the destinations that lose the tokens for
   certain are refused outright (the zero address, the token's own contract), and the ones that may lose them are
   flagged: a contract recipient needs the sender's explicit confirmation, and sending to one's own wallet is noted. */

export type RecipientCheck = { block: string | null; warn: string | null; contract: boolean };

const ZERO = "0x0000000000000000000000000000000000000000";

/** EIP-7702 delegation code (0xef0100 followed by the delegate's address): an externally owned account that delegates
    to a contract. Many Monad wallets carry it; it is not a contract recipient. */
export const isDelegatedAccount = (code: Hex) => /^0xef0100[0-9a-fA-F]{40}$/.test(code);

/** `code` is the recipient's bytecode (undefined or "0x" for none), or null while it is being read. */
export function checkRecipient(to: string, token: { address: Address; symbol: string; native?: boolean }, sender: Address | null, code: Hex | undefined | null): RecipientCheck {
  const input = to.trim();
  if (!isAddress(input)) return { block: "Enter a valid address (0x and 40 hex characters, checksum intact).", warn: null, contract: false };
  const address = getAddress(input);
  if (address === ZERO) return { block: "That is the zero address. Anything sent there is burned.", warn: null, contract: false };
  if (!token.native && address === getAddress(token.address)) return { block: `That is the ${token.symbol} token contract itself. Tokens sent to it are lost.`, warn: null, contract: false };
  if (code && code !== "0x" && !isDelegatedAccount(code)) {
    return { block: null, warn: `That address is a contract. A contract that is not built to receive ${token.symbol} can't send it back, so only continue if you know this one does.`, contract: true };
  }
  if (sender && address === getAddress(sender)) return { block: null, warn: "That is your own wallet: the transfer only costs gas.", contract: false };
  return { block: null, warn: null, contract: false };
}
