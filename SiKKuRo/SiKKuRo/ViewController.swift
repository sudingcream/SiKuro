//
//  ViewController.swift
//  SiKKuRo
//
//  Created by betty on 7/24/25.
//

import UIKit
import AVFoundation
import SnapKit

// MARK: - SleepTalkRecorderViewController

class ViewController: UIViewController, AVAudioRecorderDelegate, AVAudioPlayerDelegate, UITableViewDataSource, UITableViewDelegate {

    // MARK: - Properties

    private var audioRecorder: AVAudioRecorder? // 실제 녹음을 위한 레코더
    private var meteringRecorder: AVAudioRecorder? // 소음 감지 모니터링을 위한 임시 레코더
    private var audioPlayer: AVAudioPlayer?
    private var meteringTimer: Timer? // 마이크 입력 레벨 모니터링 타이머
    private var isRecording = false
    private var isMonitoring = false
    private var recordingURLs: [URL] = [] // 녹음된 파일들의 URL을 저장
    private var currentRecordingURL: URL? // 현재 녹음 중인 파일의 URL

    private let noiseThreshold: Float = -50.0 // 소음 감지 임계값 (dBFS, -160.0 ~ 0.0)
    private let silenceDurationThreshold: TimeInterval = 3.0 // 소음이 없다고 판단하는 지속 시간 (초)
    private var silenceTimer: Timer? // 소음이 없을 때 카운트다운하는 타이머
    private var recordStartTime: Date?
    // MARK: - UI Components

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "모니터링 시작 대기 중..."
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .darkGray
        return label
    }()

    private let monitorButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("모니터링 시작", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 22, weight: .bold)
        button.backgroundColor = .systemGreen
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 25
        button.clipsToBounds = true
        button.addTarget(self, action: #selector(toggleMonitoring), for: .touchUpInside)
        return button
    }()
    
    private let resetButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("모든 녹음 삭제", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.backgroundColor = .systemRed.withAlphaComponent(0.8)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 20
        button.clipsToBounds = true
        button.addTarget(self, action: #selector(deleteAllRecordings), for: .touchUpInside)
        return button
    }()

    private let recordingsTableView: UITableView = {
        let tableView = UITableView()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "recordingCell")
        tableView.tableFooterView = UIView() // 빈 셀 제거
        tableView.layer.cornerRadius = 10
        tableView.clipsToBounds = true
        tableView.layer.borderWidth = 1
        tableView.layer.borderColor = UIColor.lightGray.cgColor
        return tableView
    }()

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "잠꼬대 녹음기"

        setupUI()
        requestMicrophonePermission()
        loadRecordings()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.addSubview(statusLabel)
        view.addSubview(monitorButton)
        view.addSubview(recordingsTableView)
        view.addSubview(resetButton)

        recordingsTableView.dataSource = self
        recordingsTableView.delegate = self

        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(20)
            make.centerX.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(20)
            make.height.equalTo(40)
        }

        monitorButton.snp.makeConstraints { make in
            make.top.equalTo(statusLabel.snp.bottom).offset(20)
            make.centerX.equalToSuperview()
            make.width.equalTo(200)
            make.height.equalTo(50)
        }
        
        resetButton.snp.makeConstraints { make in
            make.top.equalTo(monitorButton.snp.bottom).offset(15)
            make.centerX.equalToSuperview()
            make.width.equalTo(180)
            make.height.equalTo(40)
        }

        recordingsTableView.snp.makeConstraints { make in
            make.top.equalTo(resetButton.snp.bottom).offset(30)
            make.leading.trailing.equalToSuperview().inset(20)
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom).inset(20)
        }
    }

    // MARK: - Audio Permissions

    private func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    print("마이크 권한 허용됨")
                    self?.setupAudioSession()
                } else {
                    print("마이크 권한 거부됨")
                    self?.statusLabel.text = "마이크 권한이 필요합니다."
                    self?.monitorButton.isEnabled = false
                    self?.showPermissionAlert()
                }
            }
        }
    }

    private func showPermissionAlert() {
        let alert = UIAlertController(
            title: "마이크 권한 필요",
            message: "잠꼬대 녹음 앱을 사용하려면 마이크 접근 권한이 필요합니다. 설정에서 허용해주세요.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "확인", style: .default))
        present(alert, animated: true, completion: nil)
    }

    // MARK: - Audio Session Setup

    private func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // 녹음 및 재생을 위한 카테고리 설정
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            print("오디오 세션 설정 완료")
        } catch {
            print("오디오 세션 설정 실패: \(error.localizedDescription)")
            statusLabel.text = "오디오 설정 오류"
            monitorButton.isEnabled = false
        }
    }

    // MARK: - Recording Management

    private func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }

    private func getRecordingURL(filename: String) -> URL {
        return getDocumentsDirectory().appendingPathComponent(filename)
    }
    
    private func loadRecordings() {
        let fileManager = FileManager.default
        let documentsDirectory = getDocumentsDirectory()
        
        do {
            let fileURLs = try fileManager
                .contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            recordingURLs = fileURLs
                .filter {
                    $0.pathExtension == "m4a"
                      && !$0.lastPathComponent.hasPrefix("temp_monitor")   // ← 임시 녹음 제외
                }
                .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            recordingsTableView.reloadData()
        } catch {
            print("녹음 파일 로드 실패: \(error.localizedDescription)")
        }
    }

    private func startRecording() {
        if isRecording { return } // 이미 녹음 중이면 중복 실행 방지

        // ✅ 기존 meteringRecorder가 있다면 중지 및 해제
        meteringRecorder?.stop()
        meteringRecorder?.deleteRecording() // 임시 파일 삭제
        meteringRecorder = nil

        let filename = "sleeptalk_\(Date().timeIntervalSince1970).m4a"
        currentRecordingURL = getRecordingURL(filename: filename)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: currentRecordingURL!, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true // 미터링 활성화
            audioRecorder?.record()
            recordStartTime = Date()
            isRecording = true
            statusLabel.text = "녹음 중..."
            print("녹음 시작: \(currentRecordingURL!.lastPathComponent)")
        } catch {
            print("녹음 시작 실패: \(error.localizedDescription)")
            statusLabel.text = "녹음 오류"
            isRecording = false
        }
    }

    private func stopRecording() {
        if !isRecording { return }

        audioRecorder?.stop()
        isRecording = false
        statusLabel.text = "녹음 중지됨."
        print("녹음 중지: \(currentRecordingURL?.lastPathComponent ?? "알 수 없음")")
        
        if let url = currentRecordingURL {
            recordingURLs.insert(url, at: 0)
            recordingsTableView.reloadData()
            currentRecordingURL = nil
        }
        audioRecorder = nil
        if isMonitoring {
            startMonitoringAudio()
        }
    }

    // MARK: - Audio Monitoring (Noise Detection)

    @objc private func toggleMonitoring() {
        if isMonitoring {
            stopMonitoringAudio()
        } else {
            startMonitoringAudio()
        }
    }

    private func startMonitoringAudio() {
        // ✅ 실제 녹음 중이 아니라면, meteringRecorder를 사용하여 오디오 입력 레벨만 모니터링
        if !isRecording {
            // meteringRecorder가 이미 있다면 재사용, 없다면 새로 생성
            if meteringRecorder == nil {
                let tempFilename = "temp_monitor.m4a"
                let tempURL = getRecordingURL(filename: tempFilename)
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue // 품질은 낮게 설정
                ]
                
                do {
                    meteringRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
                    meteringRecorder?.isMeteringEnabled = true
                    meteringRecorder?.prepareToRecord()
                    meteringRecorder?.record() // 실제 녹음은 하지 않고 미터링을 위해 record() 호출
                } catch {
                    print("임시 오디오 레코더 설정 실패: \(error.localizedDescription)")
                    statusLabel.text = "모니터링 오류"
                    return
                }
            } else {
                // 이미 meteringRecorder가 있다면 다시 record() 호출하여 미터링 활성화
                meteringRecorder?.record()
            }
        }

        // 0.1초마다 마이크 입력 레벨 확인
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.meteringRecorder?.updateMeters()
            let averagePower = self.meteringRecorder?.averagePower(forChannel: 0) ?? -160.0

            if averagePower > self.noiseThreshold {
                // 소음 감지 → 녹음 시작
                self.silenceTimer?.invalidate()
                if !self.isRecording { self.startRecording() }
            } else {
                // 소음 없음
                if self.isRecording {
                    // 녹음 중이고, 최소 4초가 지난 뒤에만 침묵 타이머 시작
                    let elapsed = Date().timeIntervalSince(self.recordStartTime ?? Date())
                    if elapsed >= 4.0 {
                        if self.silenceTimer == nil || !self.silenceTimer!.isValid {
                            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceDurationThreshold, repeats: false) { [weak self] _ in
                                self?.stopRecording()
                                self?.statusLabel.text = "침묵 감지. 녹음 중지됨."
                            }
                        }
                    }
                } else {
                    self.statusLabel.text = "소음 감지 대기 중..."
                }
            }
        }

        isMonitoring = true
        monitorButton.setTitle("모니터링 중지", for: .normal)
        monitorButton.backgroundColor = .systemOrange
        statusLabel.text = "소음 감지 대기 중..."
    }

    private func stopMonitoringAudio() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil

        if isRecording {
            stopRecording() // 모니터링 중지 시 녹음도 중지
        }
        
        // ✅ meteringRecorder를 중지 및 삭제
        meteringRecorder?.stop()
        meteringRecorder?.deleteRecording() // 임시 파일 삭제
        meteringRecorder = nil // 인스턴스 해제

        isMonitoring = false
        monitorButton.setTitle("모니터링 시작", for: .normal)
        monitorButton.backgroundColor = .systemGreen
        statusLabel.text = "모니터링 중지됨."
    }

    // MARK: - Audio Playback

    private func playRecording(at url: URL) {
        do {
            // ✅ 기존 플레이어가 있다면 중지
            audioPlayer?.stop()
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            statusLabel.text = "재생 중: \(url.lastPathComponent)"
            print("재생 시작: \(url.lastPathComponent)")
        } catch {
            print("재생 실패: \(error.localizedDescription)")
            statusLabel.text = "재생 오류"
        }
    }
    
    // MARK: - Delete Recordings
    
    @objc private func deleteAllRecordings() {
        // ✅ 현재 재생 중이라면 플레이어 중지
        audioPlayer?.stop()
        
        let alert = UIAlertController(
            title: "모든 녹음 삭제",
            message: "정말로 모든 녹음 파일을 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        alert.addAction(UIAlertAction(title: "삭제", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            let fileManager = FileManager.default
            let documentsDirectory = self.getDocumentsDirectory()
            
            do {
                let fileURLs = try fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
                for fileURL in fileURLs {
                    try fileManager.removeItem(at: fileURL)
                }
                self.recordingURLs.removeAll()
                self.recordingsTableView.reloadData()
                print("모든 녹음 파일이 삭제되었습니다.")
                self.statusLabel.text = "모든 녹음 삭제 완료."
            } catch {
                print("모든 녹음 파일 삭제 실패: \(error.localizedDescription)")
                self.statusLabel.text = "삭제 오류"
            }
        })
        present(alert, animated: true, completion: nil)
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if flag {
            print("녹음 성공")
            statusLabel.text = "녹음 완료."
        } else {
            print("녹음 실패")
            statusLabel.text = "녹음 실패."
            // 녹음 실패 시 파일 삭제
            if let url = currentRecordingURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        currentRecordingURL = nil // 현재 녹음 URL 초기화
        audioRecorder = nil // ✅ 녹음 완료 후 audioRecorder 인스턴스 해제
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("오디오 인코딩 오류: \(error?.localizedDescription ?? "알 수 없음")")
        statusLabel.text = "인코딩 오류"
        // 오류 발생 시 녹음 중지 및 파일 삭제
        audioRecorder?.stop()
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        isRecording = false
        currentRecordingURL = nil
        audioRecorder = nil // ✅ 오류 발생 시에도 인스턴스 해제
        
        // ✅ 오류 발생 후 다시 모니터링 시작 (선택 사항, 필요에 따라)
        if isMonitoring {
            startMonitoringAudio()
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("재생 완료")
        statusLabel.text = "재생 완료."
        audioPlayer = nil // ✅ 재생 완료 후 플레이어 인스턴스 해제
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("오디오 디코딩 오류: \(error?.localizedDescription ?? "알 수 없음")")
        statusLabel.text = "디코딩 오류"
        audioPlayer = nil // ✅ 오류 발생 시 플레이어 인스턴스 해제
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return recordingURLs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "recordingCell", for: indexPath)
        let url = recordingURLs[indexPath.row]
        cell.textLabel?.text = url.lastPathComponent
        cell.textLabel?.textColor = .black
        cell.selectionStyle = .blue
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let url = recordingURLs[indexPath.row]
        playRecording(at: url)
        tableView.deselectRow(at: indexPath, animated: true) // 선택 해제 애니메이션
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            // ✅ 현재 재생 중인 파일이라면 플레이어 중지
            if audioPlayer?.url == recordingURLs[indexPath.row] {
                audioPlayer?.stop()
                audioPlayer = nil
            }
            
            let fileURLToDelete = recordingURLs[indexPath.row]
            do {
                try FileManager.default.removeItem(at: fileURLToDelete)
                recordingURLs.remove(at: indexPath.row)
                tableView.deleteRows(at: [indexPath], with: .fade)
                print("파일 삭제됨: \(fileURLToDelete.lastPathComponent)")
                statusLabel.text = "파일 삭제 완료."
            } catch {
                print("파일 삭제 실패: \(error.localizedDescription)")
                statusLabel.text = "파일 삭제 오류"
            }
        }
    }
}
