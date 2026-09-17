import AVFoundation
import BigInt
import DyorKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Publish a Moment: the photo (uploaded to DyorHQ's media bucket and fingerprinted with keccak-256 on-chain, or a
/// link you already host), the name and coin ticker, where and when it happened, the collect price, your coin
/// allocation and how long collecting stays open. Everything is fixed at publish; the preview shows the economics
/// exactly as the contract will apply them.
struct CreateMomentView: View {
    let policy: MomentPolicy?
    /// Called after the publish transaction settles; the new Moment is passed when it could be resolved.
    let onPublished: (MomentInfo?) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(SocialSession.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = ""
    @State private var place = ""
    @State private var date = Date()
    @State private var mediaURI = ""
    @State private var mediaHash: Data?
    @State private var animationURI = ""
    @State private var priceText = "1"
    @State private var allocPercentText = "10"
    @State private var windowDays = 30
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var imageError: String?
    @State private var isVideo = false
    @State private var showConfirm = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var symbolValid: Bool { symbol.count >= 2 && symbol.count <= 10 && symbol.allSatisfy { $0.isLetter || $0.isNumber } }
    private var price: BigUInt? { Amount.parse(priceText, decimals: MomentsConstants.usdcDecimals) }
    private var allocBps: Int? {
        guard let percent = Double(allocPercentText.replacingOccurrences(of: ",", with: ".")), percent >= 0 else { return nil }
        return Int((percent * 100).rounded())
    }
    private var maxAllocBps: Int { min(policy?.maxCreatorAllocBps ?? MomentsConstants.maxCreatorAllocBps, MomentsConstants.maxCreatorAllocBps) }
    private var mediaValid: Bool {
        let uri = mediaURI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return uri.hasPrefix("ipfs://") || uri.hasPrefix("https://")
    }
    private var animationValid: Bool {
        let uri = animationURI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return uri.isEmpty || uri.hasPrefix("ipfs://") || uri.hasPrefix("https://")
    }
    private var priceProblem: String? {
        guard let price, price > 0 else { return "Enter a collect price in USDC." }
        if let policy, price < policy.minPrice { return "The minimum price is \(MomentsFormat.usdc(policy.minPrice))." }
        return nil
    }
    private var allocProblem: String? {
        guard let allocBps else { return "Enter your allocation as a percentage." }
        if allocBps > maxAllocBps { return "At most \(NumberStyle.basisPoints(maxAllocBps)) of the supply." }
        return nil
    }
    private var valid: Bool {
        trimmedName.count >= 2 && trimmedName.count <= 48 && symbolValid && !place.trimmingCharacters(in: .whitespaces).isEmpty && place.count <= 64
            && mediaValid && animationValid && priceProblem == nil && allocProblem == nil && !uploading && policy != nil && policy?.publishingPaused != true
    }

    /// The provenance hash: the uploaded bytes' keccak-256 when a photo was chosen, else the hash of the link itself.
    private var effectiveMediaHash: Data {
        mediaHash ?? Keccak.hash256(Data(mediaURI.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    private var input: MomentPublishInput? {
        guard valid, let price, let allocBps else { return nil }
        return MomentPublishInput(
            name: trimmedName, symbol: symbol, mediaURI: mediaURI.trimmingCharacters(in: .whitespacesAndNewlines), mediaHash: effectiveMediaHash,
            animationURI: animationURI.trimmingCharacters(in: .whitespacesAndNewlines), place: place.trimmingCharacters(in: .whitespaces), date: Int(date.timeIntervalSince1970),
            price: price, creatorAllocBps: allocBps, collectWindow: windowDays * 86_400
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                mediaSection
                Section("Moment") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, v in if v.count > 48 { name = String(v.prefix(48)) } }
                    TextField("Coin ticker", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: symbol) { _, v in symbol = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10)) }
                    TextField("Place", text: $place)
                        .onChange(of: place) { _, v in if v.count > 64 { place = String(v.prefix(64)) } }
                    DatePicker("When", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }
                economicsSection
                if valid { previewSection }
            }
            .navigationTitle("Publish a Moment")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { Haptics.tap(); showConfirm = true }.fontWeight(.semibold).disabled(!valid || !session.canSign) }
            }
            .sheet(isPresented: $showConfirm) {
                if let input, let policy {
                    ConfirmationSheet(
                        title: "Publish \(input.symbol)", confirmTitle: "Publish",
                        build: { await env.moments.publishPlan(input) },
                        onDone: { dismiss(); onPublished(nil) },
                        onCompleted: { hash in
                            ActivityLog.record(ActivityRecord(kind: .moment, title: "Published \(input.name)", subtitle: "$\(input.symbol) · \(MomentsFormat.usdc(input.price)) per edition", hash: hash), owner: session.address)
                            Task {
                                // Resolve the new Moment from the receipt and open it.
                                guard let result = (try? await env.moments.publishResult(transaction: hash)) ?? nil,
                                      let info = (try? await env.moments.info(id: result.momentId)) ?? nil else { return }
                                onPublished(info)
                            }
                        }
                    ) {
                        DetailRow("Moment", "\(input.name) ($\(input.symbol))")
                        DetailRow("Collect price", MomentsFormat.usdc(input.price))
                        DetailRow("Graduates at", "\(MomentsFormat.usdc(policy.threshold)) reserve")
                        DetailRow("Your coins", "\(NumberStyle.basisPoints(input.creatorAllocBps)) · \(MomentsFormat.coins(MomentsConstants.supply * BigUInt(input.creatorAllocBps) / BigUInt(MomentsConstants.bps)))")
                        DetailRow("Window", "\(windowDays) \(windowDays == 1 ? "day" : "days")")
                        DetailRow("Media", mediaHash == nil ? "link, hashed" : (isVideo ? "video, fingerprinted" : "photo, fingerprinted"))
                    }
                }
            }
            .onChange(of: photoItem) { _, item in if let item { Task { await upload(item) } } }
        }
    }

    // MARK: Sections

    private var mediaSection: some View {
        Section {
            HStack(spacing: 16) {
                MomentArtwork(provenance: MomentProvenance(mediaURI: mediaURI, mediaHash: Data(), place: "", date: 0, animationURI: ""), symbol: symbol.isEmpty ? "?" : symbol)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                        Label(mediaHash == nil ? "Choose Photo or Video" : (isVideo ? "Change Video" : "Change Photo"), systemImage: isVideo ? "video" : "photo").font(.subheadline.weight(.medium))
                    }
                    .disabled(uploading)
                    if uploading {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Uploading…").font(.caption).foregroundStyle(.secondary) }
                    } else if let imageError {
                        Text(imageError).font(.caption).foregroundStyle(Color.attention)
                    } else if let mediaHash {
                        Text("Fingerprint \(mediaHash.hexString.prefix(12))… goes on-chain.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("This becomes the NFT.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            TextField("Or paste an image link (ipfs:// or https://)", text: $mediaURI)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: mediaURI) { old, new in if old != new, mediaHash != nil, !new.hasPrefix("https://") { mediaHash = nil; isVideo = false } }
            TextField("Video link (optional)", text: $animationURI)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: {
            Text("Media")
        } footer: {
            if !mediaURI.isEmpty, !mediaValid { Text("Use an ipfs:// or https:// link.") }
            else if !animationValid { Text("The video link must be ipfs:// or https://.") }
            else if isVideo { Text("The video plays on OpenSea; its cover frame is the NFT image.") }
            else { Text("Shown on OpenSea and in DyorHQ as the NFT.") }
        }
    }

    private var economicsSection: some View {
        Section {
            HStack {
                Text("Collect price")
                Spacer()
                TextField("1", text: $priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 110)
                Text("USDC").foregroundStyle(.secondary)
            }
            HStack {
                Text("Your allocation")
                Spacer()
                TextField("10", text: $allocPercentText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 110)
                Text("%").foregroundStyle(.secondary)
            }
            Stepper(value: $windowDays, in: 1...30) {
                HStack { Text("Collect window"); Spacer(); Text("\(windowDays) \(windowDays == 1 ? "day" : "days")").monospacedDigit().foregroundStyle(.secondary) }
            }
        } header: {
            Text("Economics")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let priceProblem { Text(priceProblem).foregroundStyle(Color.attention) }
                if let allocProblem { Text(allocProblem).foregroundStyle(Color.attention) }
                if let policy, let price, price > 0 {
                    let reservePerCollect = price * BigUInt(policy.reserveBps) / BigUInt(MomentsConstants.bps)
                    let collects = reservePerCollect > 0 ? (policy.threshold + reservePerCollect - 1) / reservePerCollect : 0
                    Text("Minimum \(MomentsFormat.usdc(policy.minPrice)). About \(collects) collects at this price reach the \(MomentsFormat.usdc(policy.threshold)) reserve. Up to \(NumberStyle.basisPoints(maxAllocBps)) of the \(MomentsFormat.coins(MomentsConstants.supply)) coins is yours, vesting 20% at graduation then 16% a month; anything you leave deepens the pool. Collecting ends at graduation or when the window closes (1 to 30 days).")
                } else if policy == nil {
                    Text("Loading the current policy…")
                }
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            if let policy, let price, let allocBps {
                let creatorCoins = MomentsConstants.supply * BigUInt(allocBps) / BigUInt(MomentsConstants.bps)
                DetailRows {
                    DetailRow("Collect price", MomentsFormat.usdc(price))
                    DetailRow("Graduates at", "\(MomentsFormat.usdc(policy.threshold)) reserve")
                    DetailRow("Each collect", "\(NumberStyle.basisPoints(policy.reserveBps)) reserve · \(NumberStyle.basisPoints(policy.creatorBps)) you · \(NumberStyle.basisPoints(policy.platformBps)) DyorHQ")
                    DetailRow("Your coins", "\(MomentsFormat.coins(creatorCoins)) (\(NumberStyle.basisPoints(allocBps)))")
                    DetailRow("Collectors + pool", "\(MomentsFormat.coins(MomentsConstants.supply - creatorCoins)) at one price")
                    DetailRow("NFT royalty", NumberStyle.basisPoints(policy.royaltyBps))
                    DetailRow("Trading fee after graduation", "1.5% (0.2% to you)")
                    DetailRow("Window closes", Date().addingTimeInterval(TimeInterval(windowDays * 86_400)).formatted(date: .abbreviated, time: .shortened))
                    DetailRow("Liquidity", "Locked forever", tint: .positive)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Upload

    private func upload(_ item: PhotosPickerItem) async {
        uploading = true; imageError = nil
        defer { uploading = false; photoItem = nil }
        do {
            if !social.isSignedIn { await social.signIn(session: session) }
            guard social.isSignedIn else { imageError = "Connect DyorHQ Social to upload a photo, or paste a link instead."; return }
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                // A video: the file itself is the NFT's animation and is fingerprinted; a frame from it is the image.
                guard let movie = try await item.loadTransferable(type: MovieFile.self) else { imageError = "That video could not be read."; return }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                let data = try Data(contentsOf: movie.url)
                guard data.count <= 50 * 1024 * 1024 else { imageError = "Videos up to 50 MB."; return }
                guard let poster = try await MovieFile.coverFrame(url: movie.url)?.avatarJPEG(maxDimension: 2048, quality: 0.9) else { imageError = "Could not read a frame from that video."; return }
                let type = UTType(filenameExtension: movie.url.pathExtension) ?? .quickTimeMovie
                let isMP4 = type.conforms(to: .mpeg4Movie)
                let posterURL = try await social.uploadMomentMedia(poster, contentType: "image/jpeg", fileExtension: "jpg")
                let videoURL = try await social.uploadMomentMedia(data, contentType: isMP4 ? "video/mp4" : "video/quicktime", fileExtension: isMP4 ? "mp4" : "mov")
                mediaURI = posterURL.absoluteString
                animationURI = videoURL.absoluteString
                mediaHash = Keccak.hash256(data)
                isVideo = true
            } else {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let jpeg = image.avatarJPEG(maxDimension: 4096, quality: 0.92) else {
                    imageError = "That photo could not be read."
                    return
                }
                let url = try await social.uploadMomentImage(jpeg: jpeg)
                mediaURI = url.absoluteString
                if isVideo { animationURI = "" }
                mediaHash = Keccak.hash256(jpeg)
                isVideo = false
            }
            Haptics.success()
        } catch {
            imageError = describe(error)
        }
    }
}


/// A video picked from the library, copied to a temporary file so it can be read, hashed, uploaded and sampled.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = URL.temporaryDirectory.appending(path: "moment-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }

    /// The frame one second in (or the first frame of a shorter clip), as the NFT's cover image.
    static func coverFrame(url: URL) async throws -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2048, height: 2048)
        let duration = try await asset.load(.duration)
        let at = CMTime(seconds: min(1, max(0, duration.seconds / 2)), preferredTimescale: 600)
        let (image, _) = try await generator.image(at: at)
        return UIImage(cgImage: image)
    }
}
