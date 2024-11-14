//
//  PhotoManager.swift
//  SpyneCamera
//
//  Created by Aryan Sharma on 11/11/24.
//

import Foundation
import RealmSwift
import PhotosUI

@Observable class PhotoManager: NSObject {
    private let urlRequestBuilder: UrlRequestBuilder = UrlRequestBuilder()
    private let realmManager: RealmManager = RealmManager()
    private let fileManager: DataFileManager = DataFileManager()
    @ObservationIgnored lazy private var networkService: NetworkService = { [unowned self] in
        NetworkService(session: URLSession(configuration: .default, delegate: self, delegateQueue: .main))
    }()
    
    // Acts like a serial queue
    private var pendingUploadRequests: [Photo] = []
    private var uploadInProgress: Bool = false
    private(set) var uploadingTaskProgress: (taskID: String, progress: Float) = ("empty", 0)
    
    override init() {
        print("init: Photo Service")
    }
    
    deinit {
        print("deinit: Photo Service")
    }
    
    func savePhoto(_ uiImage: UIImage) throws {
        let photoName = UUID().uuidString
        guard let jpegPhotoData = uiImage.jpegData(compressionQuality: 1.0) else {
            throw PhotoManagerError.convertingUIImageToJpegData
        }
        
        guard let photoFileUrl = fileManager.generatePathUrl(forFileName: photoName, fileExtension: "jpg", in: .documentDirectory) else {
            throw PhotoManagerError.generatingPathUrl
        }
        
        try fileManager.writeData(jpegPhotoData, atPath: photoFileUrl)
        
        try saveToRealm(url: photoFileUrl, name: photoName)
    }
    
    func requestUploadToCloud(photo: Photo) throws {
        guard !photo.isUploaded else { return }
        guard !(pendingUploadRequests.contains { $0.name == photo.name }) else { return }
        pendingUploadRequests.append(photo)
        
        guard !uploadInProgress else { return }
        uploadInProgress = true
    
        Task {
            do {
                try await processNextPhotoUpload()
            } catch {
                throw error
            }
        }
    }
    
    @MainActor private func processNextPhotoUpload() async throws {
        guard !pendingUploadRequests.isEmpty, let photo = pendingUploadRequests.first else {
            uploadInProgress = false
            return
        }
        
        let photoDTO = PhotoDTO(from: photo)
        
        do {
            try await uploadToCloud(photoDTO)
        } catch {
            throw error
        }
        
        pendingUploadRequests.removeFirst()
        print("Pending uploads count: \(pendingUploadRequests.count)")
        
        // Recursive
        try await processNextPhotoUpload()
    }
    
    private func uploadToCloud(_ photo: PhotoDTO) async throws {
        let photoData: Data
        do {
            photoData = try Data(contentsOf: URL(filePath: photo.urlPathString))
        } catch {
            throw PhotoManagerError.loadingPhotoData
        }
    
        let url: URL = API.urlForEndpoint(.upload)
        let boundry: String = photo.name
        let bodyData: Data = urlRequestBuilder.createHttpBody(mimeType: .jpgImage, fileName: photo.name, field: "image", data: photoData, boundary: boundry)
        let urlRequest: URLRequest = urlRequestBuilder.buildRequest(url: url, method: .post, mimeType: .multiPart(boundary: boundry), body: bodyData)
        let result = await networkService.uploadTask(with: urlRequest, taskID: photo.name)
        
        switch result {
        case .success(_):
            await MainActor.run {
                guard let photoObject: Photo = realmManager.objectForKey(primaryKey: photo.name) else { return }
                try? realmManager.update {
                    photoObject.isUploaded = true
                }
            }
        case .failure(let error):
            throw error
        }
    }
    
    @discardableResult
    private func saveToRealm(url: URL, name: String) throws -> Photo {
        let photo = Photo()
        photo.captureDate = Date()
        photo.name = name
        photo.urlPathString = url.path
        
        try realmManager.add(object: photo)
        return photo
    }
    
    func allPhotos() -> Results<Photo> {
        realmManager.readAll()
    }
}

extension PhotoManager: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let taskID = task.taskDescription else { return }
        let progress = Float(totalBytesSent) / Float(totalBytesExpectedToSend)
        if progress >= 1.0 {
            uploadingTaskProgress = ("", 0)
        } else {
            uploadingTaskProgress = (taskID, progress)
        }
        print("progress: ", totalBytesSent , totalBytesExpectedToSend)
    }
}