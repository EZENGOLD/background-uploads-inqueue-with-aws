//
//  UploadService.swift
//  BackUploadsWithAws
//
//  Created by ezen on 12/09/2023.
//

import Foundation
import AWSS3

final class UploadService {
	
	static let shared = UploadService()

	static let UPLOAD_TEMP_PATH: String = "uploads"
	
	@Published var hasNoOngoingUploads: Bool = true
	
	@Published var ongoingUploads = [UploadFile]()
	
	var updateAFileUseCase = UpdateAFileUseCase(api: ChatFolderApi.shared)
	
	@objc
	lazy var transferUtility = {
		AWSS3TransferUtility.default()
	}()
	
	private var isUploading: Bool = false
	
	var delegate: UploadTaskDelegate?
	
	// MARK: - Queuing methods
	private var queue = [UploadFile]()
	
	func addUploadOperation(_ file: UploadFile) {
		self.queue.append(file)
		self.saveQueue()
	}
	
	func addMultipleUploadOperations(_ files: [UploadFile]) {
		self.queue.append(contentsOf: files)
		self.saveQueue()
	}
	
	private func nextFile() -> UploadFile? {
		return self.queue.first(where: { $0.status == .pending })
	}
	
	func getFileFromQueue(_ fileId: String) -> UploadFile? {
		return self.queue.first(where: { $0.id == fileId })
	}
	
	func purifyQueue() {
		self.queue = self.queue.filter({ $0.status != .success })
		self.saveQueue()
	}
	
	func getQueue() -> [UploadFile] {
		return self.queue
	}
	
	func removeFromQueue(_ fileId: String) {
		if let file = self.queue.first(where: { $0.id == fileId }) {
			UploadService.removeFromUploadsDirectoryIfExists(file)
		}
		self.queue.removeAll(where: { $0.id == fileId })
		self.saveQueue()
	}
	
	func saveQueue() {
		do {
			DispatchQueue.main.async {
				if self.queue.isEmpty {
					self.hasNoOngoingUploads = true
				} else {
					self.hasNoOngoingUploads = self.queue.contains(where: { ![TaskStatus.pending, TaskStatus.running, TaskStatus.error].contains($0.status) })
				}
				self.ongoingUploads = self.queue.filter({ [TaskStatus.pending, TaskStatus.running, TaskStatus.error].contains($0.status) })
			}
			
			let encoder = JSONEncoder()
			let data = try encoder.encode(self.queue)
			let jsonString = String(data: data, encoding: .utf8)
			UserDefaults.standard.set(jsonString, forKey: Constants.UPLOAD_QUEUE_PREFS_STATE_KEY)
		} catch {
			debugPrint("Error occured while saving Upload Queue in UserDefaults")
		}
	}
	
	func uploadThisFile(_ fileId: String) {
		if let position = self.queue.firstIndex(where: { $0.id == fileId }) {
			self.queue[position].status = .pending
			self.saveQueue()
			self.start()
			self.delegate?.onStart(currentFile: self.queue[position])
		}
	}
	
	// MARK: - Main methods
	
	func startOnLaunch() {
		self.queue = self.queue.map({ file in
			var copy = file
			copy.status = file.status == .error && file.error == "Finish unexpectedly" ? .pending : file.status
			return copy
		})
		self.saveQueue()
		self.start()
	}
	
	func start() {
		if !self.isUploading {
			if let nextUploadFile = self.nextFile(), let safeFileUrl = nextUploadFile.getActualUrl() {
				guard let currentIndex = self.queue.firstIndex(where: { 
					$0.s3UploadKey == nextUploadFile.s3UploadKey
				}) else { return }
				
				let expression = AWSS3TransferUtilityUploadExpression()
				expression.setValue("public-read", forRequestHeader: "x-amz-acl")
				
				expression.progressBlock = { task, progress in
					self.queue[currentIndex].progress = (progress.fractionCompleted * 100.0).toPercentage()
					self.delegate?.onProgressing(
						currentFile: self.queue[currentIndex],
						progressionInPercentage: (progress.fractionCompleted * 100.0).toPercentage(),
						uploadTask: task
					)
				}
				
				self.queue[currentIndex].progress = 0.0
				self.queue[currentIndex].status = .running
				self.saveQueue()
				
				self.isUploading = true
				
				self.delegate?.onStart(currentFile: self.queue[currentIndex])
				
				self.transferUtility.uploadFile(
					safeFileUrl,
					bucket: S3Keys.shared.s3Bucket,
					key: nextUploadFile.s3UploadKey,
					contentType: nextUploadFile.contentType.contentTypeOf(fileWithExtension: nextUploadFile.fileUrl?.pathExtension ?? ""),
					expression: expression,
					completionHandler: { task, error in
						
						if error == nil {
							self.isUploading = false
							
							let url = AWSS3.default().configuration.endpoint.url
							let publicURL = url?.appendingPathComponent(S3Keys.shared.s3Bucket).appendingPathComponent(nextUploadFile.s3UploadKey)
							
							self.queue[currentIndex].publicUrl = publicURL?.absoluteString ?? ""
							self.queue[currentIndex].error = nil
							
							/**
							 You can implement a general request call here right after the upload before continuing on the next file.
							 Maybe send the publicUrl to a backend. Keep in mind to change the file status in queue if only that request comes succeeded.
							 Here, we will use an internal function with callback to simulate the backend.
							 */

							self.setAsUploaded(file: self.queue[currentIndex]) { isSuccess, finalFile in
								if isSuccess {
									self.queue[currentIndex] = finalFile
									
									// Remove file from file manager
									UploadService.removeFromUploadsDirectoryIfExists(self.queue[currentIndex])
									UploadService.shared.purifyQueue()
									
									self.saveQueue()
									
									if let d = self.delegate {
										d.onCompleted(finalFile: finalFile, uploadTask: task) { canContinue in
											if canContinue {
												// Upload next file if exists in queue
												if self.nextFile() != nil {
													self.start()
												}
											}
										}
									} else {
										// Upload next file if exists in queue
										if self.nextFile() != nil {
											self.start()
										}
									}
								} else {
									UIApplication.getPresentedViewController()?.toast("An error occured while posting")
									
									// set error on file
									self.queue[currentIndex] = finalFile
									self.queue[currentIndex].publicUrl = ""
									self.delegate?.onError(currentFile: self.queue[currentIndex], errorEncountered: error, uploadTask: task)
									
									// Upload next file if exists in queue
									if self.nextFile() != nil {
										self.start()
									}
								}
							}
						} else {
							self.isUploading = false
							
							self.queue[currentIndex].status = .error
							self.queue[currentIndex].publicUrl = ""
							self.queue[currentIndex].error = error?.localizedDescription
							self.delegate?.onError(currentFile: self.queue[currentIndex], errorEncountered: error, uploadTask: task)
							
							// Upload next file if exists in queue
							if self.nextFile() != nil {
								self.start()
							}
						}
					}
				).continueWith { task -> Any? in
					if let error = task.error {
						self.isUploading = false
						
						self.queue[currentIndex].status = .error
						self.queue[currentIndex].publicUrl = ""
						self.queue[currentIndex].error = error.localizedDescription
						self.delegate?.onError(currentFile: self.queue[currentIndex], errorEncountered: error, uploadTask: nil)
						self.saveQueue()
						
						// Upload next file if exists in queue
						if self.nextFile() != nil {
							self.start()
						}
					}
					
					return nil
				}
			}
		}
	}
	
	private func setAsUploaded(file: UploadFile, onFinished: @escaping (Bool, UploadFile) -> Void) {
		do {
			// Call callback conditionnaly based on the request response
			var finalFile = file
			finalFile.status = .success
			finalFile.error = ""

			try updateAFileUseCase.execute(forFile: finalFile, shouldUpdateStatus: true)
			
			NotificationCenter.default.post(name: .refreshChats, object: nil)
			
			onFinished(true, finalFile)
		} catch {
			var finalFile = file
			finalFile.status = .error
			finalFile.error = "Error occured while finishing upload"
			
			onFinished(true, finalFile)
		}
	}
	
	// MARK: - Class methods
	static func initialize() {

		guard let jsonString = UserDefaults.standard.string(forKey: Constants.UPLOAD_QUEUE_PREFS_STATE_KEY) else { return }
		
		guard let jsonData = jsonString.data(using: .utf8) else { return }
		
		do {
			let decoder = JSONDecoder()
			
			let files = try decoder.decode([UploadFile].self, from: jsonData)
			
			// remove expired files if in directory
			let expiredFiles = files.filter({ $0.isExpired() })
			
			if !expiredFiles.isEmpty {
				for file in expiredFiles {
					UploadService.removeFromUploadsDirectoryIfExists(file)
				}
			}
			
			UploadService.shared.queue = files.filter({ !$0.isExpired() }).map({ file in
				var copy = file
				copy.fileUrl = file.getActualUrl()
				copy.status = .error
				copy.error = "Finish unexpectedly"
				copy.progress = 0.0
				return copy
			})
			
			UploadService.shared.saveQueue()
		} catch {
			debugPrint("Error occured while decoding saved Upload Queue : \(error.localizedDescription)")
		}
	}
	
	static func getPermanentUrl(_ url: URL, usingName fileName: String, fileType type: FileType) -> URL? {
		
		do {
			guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
				return nil
			}
			
			try UploadService.createUploadsDirectoryIfNoExists()
			
			let dirPathString = documentsDirectory.appendingPathComponent(UploadService.UPLOAD_TEMP_PATH)

			let permanentURL = dirPathString.appendingPathComponent(fileName)
			
			// Files are picked from the Files explorer, and access should be granted before
			if type == .file {
				
				if url.startAccessingSecurityScopedResource() {
					try FileManager.default.copyItem(at: url, to: permanentURL)
					
					url.stopAccessingSecurityScopedResource()
					
					return permanentURL
				} else {
					return nil
				}
			} else {
				
				// Videos are already copied to a temporary directory while picking with YPImagePicker. We move it to the uploads directory
				try FileManager.default.moveItem(at: url, to: permanentURL)
				
				return permanentURL
			}
		} catch {
			return nil
		}
	}
	
	static func getPermanentUrl(_ image: UIImage, usingName fileName: String) -> URL? {
		
		do {
			guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
				return nil
			}
			
			try UploadService.createUploadsDirectoryIfNoExists()
			
			let dirPathString = documentsDirectory.appendingPathComponent(UploadService.UPLOAD_TEMP_PATH)
			let permanentURL = dirPathString.appendingPathComponent(fileName)
			
			guard let imageData = image.jpegData(compressionQuality: 1.0) else {
				return nil
			}
			
			try imageData.write(to: permanentURL)
			
			return permanentURL
		} catch {
			return nil
		}
	}
	
	static func createUploadsDirectoryIfNoExists() throws {
		let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
		let documentDirectory = paths.first! as NSString
		let dirPathString = documentDirectory.appendingPathComponent(UploadService.UPLOAD_TEMP_PATH)

		try FileManager.default.createDirectory(atPath: dirPathString, withIntermediateDirectories: true, attributes:nil)
	}
	
	static func isInUploadsDirectory(_ file: UploadFile) -> Bool {
		let documentsDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first! as URL
		let dirFolderUrl = documentsDirectoryURL.appendingPathComponent(UploadService.UPLOAD_TEMP_PATH)
		let checkingURL = dirFolderUrl.appendingPathComponent(file.getFileName())
		
		var checkingPath = ""
		
		if #available(iOS 16.0, *) {
			checkingPath = checkingURL.path(percentEncoded: false)
		} else {
			checkingPath = checkingURL.path
		}

		return FileManager.default.fileExists(atPath: checkingPath)
	}
	
	static func removeFromUploadsDirectoryIfExists(_ file: UploadFile) {
		if isInUploadsDirectory(file) {
			do {
				let documentsDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first! as URL
				
				let dirFolderUrl = documentsDirectoryURL.appendingPathComponent(UploadService.UPLOAD_TEMP_PATH)
				
				let finalURL = dirFolderUrl.appendingPathComponent(file.getFileName())
				
				try FileManager.default.removeItem(at: finalURL)
				return
			} catch {
				return
			}
		}
	}
}
