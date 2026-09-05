import SwiftUI
import Speech
import AVFoundation

struct ChatView: View {
    @Bindable var viewModel: AppViewModel
    let patient: Patient
    
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isRecording = false
    @State private var isSending = false
    @State private var errorMessage = ""
    @FocusState private var isInputFocused: Bool
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    
    var body: some View {
        VStack(spacing: 0) {
            presetQuestionBar
            messageList
            Divider()
            inputBar
        }
        .onAppear {
            isInputFocused = true
        }
    }
    
    private var presetQuestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presetQuestions, id: \.self) { question in
                    Button {
                        sendMessage(question)
                    } label: {
                        Label(question, systemImage: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .disabled(isSending)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppBrand.familyAqua.opacity(0.11), in: Capsule(style: .continuous))
                    .foregroundStyle(AppBrand.familyAqua)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(AppBrand.familyAqua.opacity(0.20), lineWidth: 1)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }
    
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(AppBrand.familyAqua)
                            Text("选择上方问题，或直接输入想了解的 ICU 状态。")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                    } else {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { oldValue, newValue in
                if let last = messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private var inputBar: some View {
        HStack(spacing: 12) {
            Button(action: toggleRecording) {
                Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle")
                    .font(.title2)
                    .foregroundStyle(isRecording ? AppBrand.sepsisRed : AppBrand.familyAqua)
            }
            .buttonStyle(.plain)
            .help(isRecording ? "点击停止录音" : "点击开始语音输入")
            
            VStack(alignment: .leading, spacing: 4) {
                TextField("输入问题...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($isInputFocused)
                    .onSubmit {
                        sendCurrentInput()
                    }
                
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            
            Button {
                sendCurrentInput()
            } label: {
                Label(isSending ? "发送中" : "发送", systemImage: isSending ? "hourglass" : "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppBrand.familyAqua)
            .disabled(trimmedInput.isEmpty || isSending)
        }
        .padding()
        .background(AppBrand.familyMist.opacity(0.48))
    }
    
    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var presetQuestions: [String] {
        [
            "今天病情怎么样？",
            "什么是脓毒症？",
            "风险评分是什么意思？",
            "患者什么时候能转出ICU？",
            "现在在治疗什么？"
        ]
    }
    
    private func sendCurrentInput() {
        let text = trimmedInput
        guard !text.isEmpty else { return }
        sendMessage(text)
    }
    
    private func sendMessage(_ text: String) {
        guard !isSending else { return }
        messages.append(ChatMessage(role: .user, text: text, timestamp: Date()))
        inputText = ""
        errorMessage = ""
        isSending = true
        
        Task {
            do {
                let response = try await viewModel.sendFamilyChat(question: text, for: patient)
                let reply = response.source == "deepseek" ? response.answer : "\(response.answer)\n\n（当前回答来源：\(response.source)）"
                await MainActor.run {
                    messages.append(ChatMessage(role: .assistant, text: reply, timestamp: Date()))
                    isSending = false
                    isInputFocused = true
                }
            } catch {
                let reply = generateFallbackReply(text)
                await MainActor.run {
                    errorMessage = "后端暂不可用，已使用本地备用回复。"
                    messages.append(ChatMessage(role: .assistant, text: "\(reply)\n\n（当前回答来源：local_fallback）", timestamp: Date()))
                    isSending = false
                    isInputFocused = true
                }
            }
        }
    }
    
    private func generateFallbackReply(_ question: String) -> String {
        if question.contains("病情") || question.contains("怎么样") {
            return "根据当前模型评估，患者处于\(patient.predictions.last?.riskLevel.displayName ?? "观察中")状态。主要生理指标显示：平均动脉压 \(Int(patient.vitals.map)) mmHg，乳酸 \(String(format: "%.1f", patient.labs.lactate)) mmol/L。建议与主管医生确认今日治疗计划。"
        } else if question.contains("脓毒症") {
            return "脓毒症是人体对感染的过度反应，可能导致器官损伤。ICU团队正在密切监测并及时干预。模型显示当前表型为\(patient.predictions.last?.phenotypeName ?? "评估中")，这有助于医生制定针对性治疗方案。"
        } else if question.contains("风险") {
            let prediction = patient.predictions.last ?? PredictionResult.mock(for: patient)
            let ventilationText = prediction.nextMVProbability >= 0.55 ? "需要重点关注" : prediction.nextMVProbability >= 0.25 ? "继续观察" : "目前较低"
            return "风险评估是基于模型对多项生理指标的综合判断。家属端只展示整体状态，不量化死亡风险；当前机械通气支持评估为\(ventilationText)，预计 ICU 停留约 \(Int(prediction.remainingLOSHours)) 小时。所有判断以主管医生说明为准。"
        } else if question.contains("转出") || question.contains("ICU") {
            return "预估剩余ICU住院时间约为 \(Int(patient.predictions.last?.remainingLOSHours ?? 0)) 小时。实际转出时间取决于患者对治疗的反应和多器官功能恢复情况，请以临床医生的判断为准。"
        } else {
            return "这是一个很好的问题。根据目前的研究模型分析，患者\(patient.name)的生理指标正在受到密切监测。具体的治疗决策和病情解释，建议您与主管医生或责任护士进行面对面沟通，他们能提供最准确的临床信息。"
        }
    }
    
    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }
        
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }
            
            Task { @MainActor in
                self.isRecording = true
                
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                
                self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                    if let result = result {
                        self.inputText = result.bestTranscription.formattedString
                    }
                    if error != nil || result?.isFinal == true {
                        self.stopRecording()
                    }
                }
                
                let inputNode = self.audioEngine.inputNode
                let recordingFormat = inputNode.outputFormat(forBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                    request.append(buffer)
                }
                
                self.audioEngine.prepare()
                try? self.audioEngine.start()
            }
        }
    }
    
    private func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
        
        if !trimmedInput.isEmpty {
            sendMessage(trimmedInput)
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    
    var isUser: Bool { message.role == .user }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if isUser { Spacer(minLength: 60) }

            if !isUser {
                avatar
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(12)
                    .background(bubbleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.primary)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isUser ? AppBrand.signalBlue.opacity(0.16) : AppBrand.familyAqua.opacity(0.16), lineWidth: 1)
                    }
                
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            if isUser {
                avatar
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }

    private var avatar: some View {
        Image(systemName: isUser ? "person.crop.circle.fill" : "cross.case.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isUser ? AppBrand.signalBlue : AppBrand.familyAqua)
            .frame(width: 30, height: 30)
            .background((isUser ? AppBrand.signalBlue : AppBrand.familyAqua).opacity(0.10), in: Circle())
    }

    private var bubbleFill: Color {
        isUser ? AppBrand.signalBlue.opacity(0.10) : Color.white.opacity(0.86)
    }
}
