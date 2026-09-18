# Moments as NFTs on OpenSea — plan (2026-09-17)

## Observe: what is already true on-chain

- Every Moment deploys its own ERC-721 collection (`MomentNFT`, OpenZeppelin ERC721Enumerable) and mints one edition
  per collect. The contract serves **on-chain metadata**: `tokenURI` is a `data:application/json;base64` document with
  `name`, `description`, `image` (the Moment's `mediaURI`), `animation_url` (when `animationURI` is set),
  `external_url` and attributes (Rank, Place, Date, Creator, Media hash, Edition size once closed). `contractURI()`
  (ERC-7572) gives the collection name, description, image and link; `royaltyInfo` (ERC-2981) pays the creator's
  royalty on marketplace sales; `owner()` returns the creator so marketplaces let them manage the collection page;
  ERC-4906 events ask indexers to refresh when the edition closes at graduation.
- OpenSea indexes Monad mainnet. The live Moment #1 ("Spectacular", NFT `0x1f247c…9DE0`, 6 editions) already renders
  on OpenSea with its image: `https://opensea.io/item/monad/0x1f247c933e903354E51f60a0708Ac686ddCf9DE0/1`.
  Item URLs are `https://opensea.io/item/monad/<nft>/<tokenId>`; the collection page is the slug OpenSea assigns.
- What the NFT points at today: the media is a JPEG in DyorHQ's Supabase bucket (`launch-media`, https URL, max 1600
  px, 5 MB), the `animation_url` slot is never filled by the app, and `external_url` is
  `https://dyorhq.fun/moments/<id>` — the factory's `externalBaseURI` was corrected from the unregistered
  `dyorhq.app` to `dyorhq.fun` on 2026-09-17 (tx `0x7f0757eb…3b75`), so every Moment (including #1) now resolves there.

## Orient: the gaps

1. **Media.** Photo only, downscaled; no video; stored on a centralized bucket. "Make your favorite moments last
   forever" needs content-addressed storage (IPFS) so the NFT's image survives DyorHQ's servers.
2. **Reach.** Nothing in the app links to OpenSea; sharing used a dead `dyorhq.app` link; the NFT has no page on
   dyorhq.fun. (Resolved: the app now links/shares to OpenSea and `external_url` points at `dyorhq.fun`.)
3. **Collection quality.** No collection banner, no metadata refresh call after graduation
   (OpenSea relies on ERC-4906 events, which it honours on most chains but not guaranteed on Monad).
4. **Discovery.** A wallet's NFTs (Moments and any other Monad collection) are not shown anywhere in the app.

## Decide: the design

- **Any photo or video becomes the NFT.** The picker accepts photos and videos. Photos: upload the full-quality JPEG
  (up to 4096 px) as `image`. Videos: upload the file (MP4/MOV, ≤ 50 MB) as `animation_url` and a generated poster
  frame as `image`; the provenance hash is the keccak-256 of the uploaded video bytes. Other file types (audio, GIF,
  3D) follow the same two-slot rule later.
- **Permanent media.** Pin every uploaded file to IPFS (Pinata) from a Supabase Edge Function that authenticates the
  wallet session and holds the Pinata key; write `ipfs://<CID>` on-chain as `mediaURI` / `animationURI`, keep the
  Supabase copy as the fast mirror the app displays. Until the Pinata key exists the app keeps writing https URLs
  (OpenSea renders both).
- **OpenSea everywhere.** "View on OpenSea" on the Moment page (collection) and on each owned edition; Share sends
  the OpenSea item link with the Moment's name; the wallet's Assets list shows every NFT with an OpenSea link.
- **Fix the link back.** Governance sets `externalBaseURI` to `https://dyorhq.fun/moments/`; the web app gains a
  `/moments/<id>` page (name, media, place, date, collect button deep-linking into the app, OpenSea link) so the
  NFT's `external_url` resolves.
- **Refresh after graduation.** When a Moment graduates (edition size fixed), call OpenSea's metadata refresh for
  the collection through an Edge Function with the OpenSea API key, in addition to the ERC-4906 event.
- **Marketing.** Moments copy leads with "Make your favorite moments last forever on the blockchain. Share them with
  everyone and earn."

## Act: phases

1. **Shipped 2026-09-17:** photo-or-video upload (video ≤ 50 MB with a generated cover frame as the NFT image and
   the video as `animation_url`, fingerprint of the file on-chain); "View on OpenSea" on every Moment page and on
   each owned edition; the collect confirmation's View control opens the new edition on OpenSea; Share sends the
   OpenSea link; the Portfolio's Assets card lists every NFT the wallet holds on Monad (Moments open in-app, others
   on OpenSea); Moments copy leads with "Make your favorite moments last forever."

2. **Needs credentials:** IPFS pinning Edge Function (`pin-media`) + `ipfs://` on-chain URIs; OpenSea refresh Edge
   Function; both keyed from Supabase secrets.
3. **Needs governance:** `setExternalBaseURI("https://dyorhq.fun/moments/")` from the owner (one transaction):
   `cast send 0x64698c7702d85F87f43a6dFF7D495CDD2327C020 "setExternalBaseURI(string)" "https://dyorhq.fun/moments/" --rpc-url https://rpc3.monad.xyz --private-key $OWNER_KEY`
4. **Web:** `/moments/<id>` page on dyorhq.fun (and the AASA/passkey files already planned there).
5. **Later:** collection banners (a DyorHQ Moments frame), OpenSea listing/floor data on the Moment page ("earn"
   angle: creator royalties from secondary sales), audio/3D media, Magic Eden link alongside OpenSea.

## Needed from the owner

- **Pinata**: an API JWT (scoped to pinFileToIPFS) and the dedicated gateway domain — or say which IPFS provider you
  prefer (NFT.Storage, Filebase, web3.storage).
- **OpenSea API key** (free, developer portal) for metadata refresh and, later, listings on the Moment page.
- Confirmation that the Moment page URL is `https://dyorhq.fun/moments/<id>` before the governance call above.
- Optional: a collection banner image for Moments collections.
