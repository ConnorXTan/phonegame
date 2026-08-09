import Foundation

/// Uploads finished killcam MP4s to the public gallery. The endpoint checks
/// the shared secret; viewing the gallery needs no auth at all.
enum ReplayPublisher {
    /// Filled in after `killcam-web` is deployed (see killcam-web/README).
    static let endpoint = URL(string: "https://killcam-web.vercel.app")!
    static let uploadKey = "e498021be18ae06ed0f911017bf43097"

    enum PublishError: Error {
        case badResponse(Int)
        case malformedReply
    }

    /// POSTs the MP4; completion (on main) carries the public clip URL.
    static func publish(mp4: URL, killer: String, victim: String, matchId: String,
                        capturedAt: Date,
                        completion: @escaping (Result<URL, Error>) -> Void) {
        func finish(_ result: Result<URL, Error>) {
            DispatchQueue.main.async { completion(result) }
        }
        var components = URLComponents(url: endpoint.appendingPathComponent("api/upload"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "killer", value: killer),
            URLQueryItem(name: "victim", value: victim),
            URLQueryItem(name: "match", value: matchId),
            URLQueryItem(name: "ts", value: String(Int(capturedAt.timeIntervalSince1970 * 1000))),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(uploadKey, forHTTPHeaderField: "X-Upload-Key")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        URLSession.shared.uploadTask(with: request, fromFile: mp4) { data, response, error in
            if let error { return finish(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return finish(.failure(PublishError.badResponse(status))) }
            guard let data,
                  let reply = try? JSONDecoder().decode(UploadReply.self, from: data),
                  let clipURL = URL(string: reply.url)
            else { return finish(.failure(PublishError.malformedReply)) }
            finish(.success(clipURL))
        }.resume()
    }

    private struct UploadReply: Decodable {
        let url: String
    }

    // MARK: - Gallery management (game master only)

    struct GalleryClip: Identifiable, Decodable {
        let url: String
        let key: String
        let killer: String
        let victim: String
        let timestamp: Double
        let likes: Int

        var id: String { key }
        var date: Date { Date(timeIntervalSince1970: timestamp / 1000) }
    }

    private struct ClipsReply: Decodable {
        let clips: [GalleryClip]
    }

    /// The gallery's current contents, for the manage view.
    static func fetchClips(completion: @escaping (Result<[GalleryClip], Error>) -> Void) {
        func finish(_ result: Result<[GalleryClip], Error>) {
            DispatchQueue.main.async { completion(result) }
        }
        let url = endpoint.appendingPathComponent("api/clips")
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error { return finish(.failure(error)) }
            guard let data,
                  let reply = try? JSONDecoder().decode(ClipsReply.self, from: data)
            else { return finish(.failure(PublishError.malformedReply)) }
            finish(.success(reply.clips))
        }.resume()
    }

    /// Removal rides the same secret as publishing — viewers can't delete.
    static func deleteClip(key: String, completion: @escaping (Result<Void, Error>) -> Void) {
        func finish(_ result: Result<Void, Error>) {
            DispatchQueue.main.async { completion(result) }
        }
        var components = URLComponents(url: endpoint.appendingPathComponent("api/delete"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "clip", value: key)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(uploadKey, forHTTPHeaderField: "X-Upload-Key")
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { return finish(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                finish(.success(()))
            } else {
                finish(.failure(PublishError.badResponse(status)))
            }
        }.resume()
    }
}
