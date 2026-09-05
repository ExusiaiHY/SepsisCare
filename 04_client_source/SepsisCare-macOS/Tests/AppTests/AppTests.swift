import XCTest
import AppKit
import SwiftUI
@testable import App

final class AppTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "sepsis.rememberedRole")
        UserDefaults.standard.removeObject(forKey: "sepsis.familyBoundPatientID")
        UserDefaults.standard.removeObject(forKey: "sepsis.backendAutoStart")
        UserDefaults.standard.removeObject(forKey: "sepsis.apiBaseURL")
        UserDefaults.standard.removeObject(forKey: "sepsis.serviceToken")
    }

    func testAuthentication() {
        let vm = AppViewModel(startBackend: false)
        XCTAssertTrue(vm.authenticate(username: "research", password: "123123"))
        XCTAssertEqual(vm.currentRole, .research)
        XCTAssertTrue(vm.isAuthenticated)
        
        vm.logout()
        XCTAssertFalse(vm.isAuthenticated)
        
        XCTAssertTrue(vm.authenticate(username: "family", password: "123123"))
        XCTAssertEqual(vm.currentRole, .family)
    }

    func testAdminAuthentication() {
        let vm = AppViewModel(startBackend: false)
        XCTAssertTrue(vm.authenticate(role: .admin, password: "123123"))
        XCTAssertEqual(vm.currentRole, .admin)
        XCTAssertTrue(vm.isAuthenticated)
    }
    
    func testAuthenticationFailure() {
        let vm = AppViewModel(startBackend: false)
        XCTAssertFalse(vm.authenticate(username: "research", password: "wrong"))
        XCTAssertFalse(vm.isAuthenticated)
    }

    func testDefaultAPIBaseURLUsesLocalBackend() {
        let settings = AppSettings()

        XCTAssertEqual(SepsisCareAPI.defaultBaseURL, "http://127.0.0.1:8765")
        XCTAssertEqual(settings.apiBaseURL, "http://127.0.0.1:8765")
        XCTAssertTrue(settings.usesLocalAPIBaseURL)
    }

    func testServiceTokenNormalizationStripsBearerPrefixAndWhitespace() {
        XCTAssertEqual(SepsisCareAPI.normalizedServiceToken("  Bearer secure-token  "), "secure-token")
        XCTAssertEqual(SepsisCareAPI.normalizedServiceToken("bearer another-token"), "another-token")
        XCTAssertEqual(SepsisCareAPI.normalizedServiceToken("  "), "")
    }

    func testAPIClientAddsBearerTokenToBuiltRequests() async throws {
        let client = APIClient()

        await client.setBaseURL("http://127.0.0.1:8765")
        await client.setServiceToken("  Bearer secure-token  ")

        let request = try await client.buildRequest(path: "/api/patients")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secure-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testAppSettingsPersistsServiceToken() {
        let settings = AppSettings()

        settings.serviceToken = "  Bearer persisted-token  "

        XCTAssertEqual(settings.serviceToken, "persisted-token")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sepsis.serviceToken"), "persisted-token")
    }
    
    func testPatientSelection() {
        let vm = AppViewModel(startBackend: false)
        let patient = Patient.mockPatients[0]
        vm.selectPatient(patient)
        XCTAssertEqual(vm.selectedPatient?.id, patient.id)
    }

    func testCurrentAnalysisPatientUsesSelectionOrQueueDefault() {
        let vm = AppViewModel(startBackend: false)
        XCTAssertEqual(vm.currentAnalysisPatient?.id, Patient.mockPatients.first?.id)

        let patient = Patient.mockPatients[12]
        vm.selectPatient(patient)
        XCTAssertEqual(vm.currentAnalysisPatient?.id, patient.id)
    }
    
    func testRoleSelectionDoesNotCollapseToFamily() {
        let vm = AppViewModel(startBackend: false)
        XCTAssertTrue(vm.authenticate(role: .research, password: "123123"))
        XCTAssertEqual(vm.currentRole, .research)
        XCTAssertNil(vm.selectedPatient)
        
        vm.logout()
        XCTAssertTrue(vm.authenticate(role: .family, password: "123123"))
        XCTAssertEqual(vm.currentRole, .family)
        XCTAssertEqual(vm.selectedPatient?.id, Patient.mockPatients.first?.id)
    }

    func testDemoPatientQueueHasFiftyCases() {
        XCTAssertEqual(Patient.mockPatients.count, 50)
        XCTAssertEqual(Set(Patient.mockPatients.map(\.maskedId)).count, 50)
    }

    func testFamilyOnlySeesBoundPatient() {
        let vm = AppViewModel(startBackend: false)
        let bound = Patient.mockPatients[7]
        let other = Patient.mockPatients[2]

        vm.bindFamilyAccount(to: bound)
        XCTAssertTrue(vm.authenticate(role: .family, password: "123123"))

        XCTAssertEqual(vm.visiblePatients.map(\.id), [bound.id])
        XCTAssertEqual(vm.selectedPatient?.id, bound.id)

        vm.selectPatient(other)
        XCTAssertEqual(vm.selectedPatient?.id, bound.id)
    }

    func testPatientListResponseDecodes() throws {
        let json = """
        {
          "patients": [
            {
              "patient_id": 12000,
              "masked_id": "SC-12000",
              "bed_no": "ICU-01",
              "admission_time": "2024-01-01",
              "icu_ward": "心内ICU",
              "risk_level": "🟢",
              "risk_score": 0.08,
              "phenotype": 0,
              "phenotype_name": "P0 低危型",
              "vitals_summary": "HR:77/BP:117/70",
              "last_prediction": "1小时前",
              "age_group": "40-60岁",
              "age": 42,
              "sex": "男",
              "mortality_flag": 0,
              "los_hours": 24,
              "prediction_consistency": {
                "label": "L5 完全一致",
                "tone": "stable",
                "match_count": 5,
                "total_windows": 5,
                "match_rate": 1.0
              }
            }
          ],
          "total": 50,
          "page": 1,
          "per_page": 20
        }
        """

        let decoded = try JSONDecoder().decode(PatientListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.total, 50)
        XCTAssertEqual(decoded.patients.first?.masked_id, "SC-12000")
        XCTAssertEqual(decoded.patients.first?.prediction_consistency.tone, "stable")
    }

    func testHistoricalPatientListResponseDecodes() throws {
        let json = """
        {
          "patients": [
            {
              "history_id": "HICU-700000",
              "masked_id": "HX-700000",
              "data_source": "MIMIC-IV",
              "center": "BIDMC",
              "icu_type": "心内ICU",
              "quality_tag": "高质量",
              "icu_admit_time": "2023-01-01 08:00",
              "icu_discharge_time": "2023-01-04 14:00",
              "los_hours": 72.5,
              "outcome": "出院存活",
              "primary_phenotype": "P0 低危稳定型",
              "phenotype_consistency": {"code": "exact", "label": "完全一致", "color": "green"},
              "parameter_consistency": {"code": "mostly", "label": "大部分一致", "color": "blue"},
              "missing_rate": 0.02,
              "available_prediction_windows": 12,
              "model_version": "S7-contrastive-20260516",
              "favorite": false,
              "annotation_status": "未标注"
            }
          ],
          "total": 500,
          "page": 1,
          "per_page": 100,
          "sort": "los_desc",
          "lazy_detail": true
        }
        """

        let decoded = try JSONDecoder().decode(HistoricalPatientListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.total, 500)
        XCTAssertTrue(decoded.lazy_detail)
        XCTAssertEqual(decoded.patients.first?.masked_id, "HX-700000")
        XCTAssertEqual(decoded.patients.first?.phenotype_consistency.color, "green")
    }

    func testICURealtimeResponsesDecode() throws {
        let statusJSON = """
        {
          "ok": true,
          "storage": "managed-runtime/icu_timeseries.jsonl",
          "total_events": 6,
          "last_event": {
            "record_id": "icu-1",
            "source": "hospital-icu-monitor-demo",
            "vitals": {"heart_rate": 112, "map": 64}
          },
          "upload": {
            "endpoint": "http://127.0.0.1:8788/api/icu/timeseries/ingest",
            "uploaded_events": 6,
            "cloud_accepted": 6,
            "training_ready": true
          }
        }
        """
        let ingestJSON = """
        {
          "ok": true,
          "accepted": 1,
          "storage": "managed-runtime/icu_timeseries.jsonl",
          "status": \(statusJSON),
          "latest_prediction": {"mortality_probability": 0.42}
        }
        """
        let uploadJSON = """
        {
          "ok": true,
          "status": \(statusJSON),
          "output": ["已上传 1 条 ICU 时序事件至云端模型服务。"],
          "cloud_response": {"accepted": 1, "training_ready": true}
        }
        """

        let status = try JSONDecoder().decode(ICURealtimeStatusResponse.self, from: Data(statusJSON.utf8))
        let ingest = try JSONDecoder().decode(ICURealtimeIngestResponse.self, from: Data(ingestJSON.utf8))
        let upload = try JSONDecoder().decode(ICURealtimeUploadResponse.self, from: Data(uploadJSON.utf8))

        XCTAssertEqual(status.total_events, 6)
        XCTAssertEqual(ingest.accepted, 1)
        XCTAssertEqual(upload.output.first, "已上传 1 条 ICU 时序事件至云端模型服务。")
        XCTAssertEqual(upload.status.storage, "managed-runtime/icu_timeseries.jsonl")
    }

    func testTrainingTerminalConfigResponseDecodesAsStatus() throws {
        let json = """
        {
          "ok": true,
          "version": "1.0.0",
          "mode": "production",
          "mode_label": "生产模型演示",
          "model_profile": "s7_phenotype_contrastive_full_20260516",
          "task_status": "synced",
          "cloud_base_url": "http://100.65.136.96:8788",
          "cloud_ready": true,
          "last_action": "sync_config",
          "updated_at": "2026-06-05T15:50:00+08:00",
          "params": {"source": "macos", "safe_mode": true},
          "metrics": {"actual_training_examples": 2, "incremental_adapter_loss": 0.679435},
          "artifacts": [{"kind": "incremental_icu_adapter", "training_examples": 2}],
          "actions": [
            {"action": "continue_training", "title": "继续训练", "shortcut": "train"}
          ],
          "notice": "训练终端配置已保存。",
          "action": "sync_config",
          "command": null,
          "output": ["训练终端配置已保存。"],
          "status": {
            "ok": true,
            "version": "1.0.0",
            "mode": "production",
            "mode_label": "生产模型演示",
            "model_profile": "s7_phenotype_contrastive_full_20260516",
            "task_status": "synced",
            "cloud_base_url": "http://100.65.136.96:8788",
            "cloud_ready": true,
            "last_action": "sync_config",
            "updated_at": "2026-06-05T15:50:00+08:00",
            "params": {"source": "macos", "safe_mode": true},
            "metrics": {"actual_training_examples": 2, "incremental_adapter_loss": 0.679435},
            "artifacts": [{"kind": "incremental_icu_adapter", "training_examples": 2}],
            "actions": [
              {"action": "continue_training", "title": "继续训练", "shortcut": "train"}
            ],
            "notice": "训练终端配置已保存。"
          },
          "error": null,
          "cloud_response": null
        }
        """

        let decoded = try JSONDecoder().decode(TrainingTerminalStatusResponse.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.cloud_base_url, "http://100.65.136.96:8788")
        XCTAssertEqual(decoded.task_status, "synced")
        XCTAssertEqual(decoded.actions.first?.action, "continue_training")
    }

    func testHistoricalPatientDetailResponseDecodes() throws {
        let json = """
        {
          "patient": {
            "history_id": "HICU-700000",
            "masked_id": "HX-700000",
            "data_source": "MIMIC-IV",
            "center": "BIDMC",
            "icu_type": "心内ICU",
            "quality_tag": "高质量",
            "icu_admit_time": "2023-01-01 08:00",
            "icu_discharge_time": "2023-01-04 14:00",
            "los_hours": 72.5,
            "outcome": "出院存活",
            "primary_phenotype": "P0 低危稳定型",
            "phenotype_consistency": {"code": "exact", "label": "完全一致", "color": "green"},
            "parameter_consistency": {"code": "mostly", "label": "大部分一致", "color": "blue"},
            "missing_rate": 0.02,
            "available_prediction_windows": 12,
            "model_version": "S7-contrastive-20260516",
            "favorite": false,
            "annotation_status": "未标注"
          },
          "resolution": "1min",
          "duration_minutes": 720,
          "grouping_modes": {
            "clinical_system": ["循环", "感染/炎症"],
            "data_source": ["生命体征", "实验室"]
          },
          "display_contract": {
            "chart_columns": 4,
            "chart_library": "Swift Charts",
            "curves": ["actual", "predicted", "error", "smoothed_predicted"],
            "missing_display": "point_markers",
            "window_overlap_display": "translucent_bands",
            "ai_summary": false
          },
          "formulae": [
            {"name": "mae", "latex": "MAE_w = \\\\frac{1}{n}\\\\sum |y_t-\\\\hat{y}_t|"}
          ],
          "parameters": [
            {
              "name": "heart_rate",
              "label": "心率",
              "unit": "bpm",
              "clinical_system": "循环",
              "data_source": "生命体征",
              "points": [
                {"minute": 0, "actual": 91.2, "predicted": 92.1, "smoothed_predicted": 91.7, "error": -0.9, "missing": false},
                {"minute": 5, "actual": null, "predicted": 93.0, "smoothed_predicted": 92.2, "error": null, "missing": true}
              ],
              "metrics": {"mae": 0.9, "rmse": 0.9, "mape": 0.98, "dtw": 1.53}
            }
          ],
          "prediction_windows": [
            {
              "window_index": 1,
              "start_minute": 0,
              "end_minute": 360,
              "phenotype_actual": "P0",
              "phenotype_predicted": "P1",
              "phenotype_consistency": {"code": "mostly", "label": "大部分一致", "color": "blue"},
              "parameter_consistency": {"code": "average", "label": "中等一致", "color": "yellow"},
              "mae": 0.08,
              "rmse": 0.12,
              "mape": 4.5,
              "dtw": 0.22,
              "key_deviation_parameters": ["lactate", "map"]
            }
          ],
          "phenotype_transition": {
            "display": "transition_matrix",
            "states": ["P0", "P1"],
            "matrix": [[0.8, 0.2], [0.1, 0.9]]
          }
        }
        """

        let decoded = try JSONDecoder().decode(HistoricalPatientDetail.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.patient.masked_id, "HX-700000")
        XCTAssertEqual(decoded.display_contract.chart_columns, 4)
        XCTAssertEqual(decoded.parameters.first?.points.last?.missing, true)
        XCTAssertEqual(decoded.prediction_windows.first?.parameter_consistency.color, "yellow")
        XCTAssertEqual(decoded.formulae.first?.name, "mae")
    }

    func testAdminBindingResponseDecodes() throws {
        let json = """
        {
          "bindings": [
            {"account": "family", "patient_ref": "SC-12007", "updated_at": "2026-05-17T23:00:00+0800"}
          ],
          "storage": "/tmp/family_bindings.json"
        }
        """

        let decoded = try JSONDecoder().decode(AdminBindingResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.bindings.first?.account, "family")
        XCTAssertEqual(decoded.bindings.first?.patient_ref, "SC-12007")
        XCTAssertTrue(decoded.storage.contains("family_bindings"))
    }

    func testAdminStatusResponseDecodesLegacyFlatRemotePayload() throws {
        let json = """
        {
          "service": "sepsiscare-legacy-model-server",
          "backend": "online",
          "device": "cpu",
          "model_id": "s7_phenotype_contrastive_full_20260516"
        }
        """

        let response = try JSONDecoder().decode(AdminStatusResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.service.name, "sepsiscare-remote-windows-model-server")
        XCTAssertEqual(response.service.status, "online")
        XCTAssertEqual(response.backend.runtime_device, "cpu")
        XCTAssertEqual(response.backend.llm_provider, "deepseek")
        XCTAssertFalse(response.backend.llm_configured)
        XCTAssertEqual(response.backend.deepseek_model, "deepseek-v4-flash")
        XCTAssertEqual(response.device.cpu.cores, 0)
        XCTAssertFalse(response.device.gpu.available)
    }

    func testAdminStatusResponseAppliesDeepSeekConfigForLegacyStatus() throws {
        let json = """
        {
          "service": "sepsiscare-legacy-model-server",
          "backend": "online",
          "device": "cpu",
          "model_id": "s7_phenotype_contrastive_full_20260516"
        }
        """
        let status = try JSONDecoder().decode(AdminStatusResponse.self, from: Data(json.utf8))
        let config = DeepSeekConfigResponse(
            provider: "deepseek",
            configured: true,
            model: "deepseek-v4-flash",
            base_url: "https://api.deepseek.com",
            timeout_seconds: "30",
            api_key_hint: "...9f26",
            config_path: "D:\\PredictionService\\models\\production\\02_model_deploy_package\\.runtime\\deepseek_config.json",
            saved: nil
        )

        let merged = status.applying(deepSeekConfig: config)

        XCTAssertTrue(merged.backend.llm_configured)
        XCTAssertEqual(merged.backend.llm_provider, "deepseek")
        XCTAssertEqual(merged.backend.deepseek_model, "deepseek-v4-flash")
    }

    func testAdminCPUStatusFormatsLoadAveragesForMonitorDisplay() {
        let cpu = AdminCPUStatus(
            cores: 18,
            load_1m: 4.8232421875,
            load_5m: 4.462890625,
            load_15m: 4.46484375,
            estimated_usage_percent: 0.6
        )

        XCTAssertEqual(cpu.load1mDisplayText, "4.82")
        XCTAssertEqual(cpu.loadAverageDisplayText, "4.82/4.46/4.46")
        XCTAssertEqual(cpu.monitorTileSubtitle, "18 cores · load 4.82")
        XCTAssertEqual(cpu.monitorChecklistDetail, "18 cores · load 4.82/4.46/4.46")
    }

    func testSidebarNavigationAccessibilityDescribesSelectionState() {
        XCTAssertEqual(
            SidebarNavAccessibility.label(title: "服务监控", subtitle: "CPU/GPU/后端/DeepSeek"),
            "服务监控，CPU/GPU/后端/DeepSeek"
        )
        XCTAssertEqual(SidebarNavAccessibility.value(isSelected: true), "已选中")
        XCTAssertEqual(SidebarNavAccessibility.value(isSelected: false), "未选中")
        XCTAssertTrue(SidebarNavAccessibility.traits(isSelected: true).contains(.isButton))
        XCTAssertTrue(SidebarNavAccessibility.traits(isSelected: true).contains(.isSelected))
        XCTAssertTrue(SidebarNavAccessibility.traits(isSelected: false).contains(.isButton))
        XCTAssertFalse(SidebarNavAccessibility.traits(isSelected: false).contains(.isSelected))
    }

    func testResearchDocumentationIncludesMathRendererAndFormulas() {
        let html = SepsisCareDocumentationHTML.research
        XCTAssertTrue(html.contains("katex"))
        XCTAssertTrue(html.contains("MathJax"))
        XCTAssertTrue(html.contains("MAE_w"))
        XCTAssertTrue(html.contains("qSOFA"))
        XCTAssertTrue(html.contains("DTW(Y"))
        XCTAssertTrue(html.contains("API 覆盖清单"))
        XCTAssertTrue(html.contains("sepsiscare 科研端使用文档"))
        XCTAssertNotNil(SepsisCareDocumentationHTML.resourceBaseURL)
    }

    func testResearchNavigationPrioritizesHistoryAndUsesClinicalLab() {
        let cases = ResearchWorkspaceSection.navigationCases
        XCTAssertEqual(cases.prefix(3), [.overview, .riskBoard, .history])
        XCTAssertTrue(cases.contains(.clinicalLab))
        XCTAssertFalse(cases.contains(.diagnosis))
        XCTAssertFalse(cases.contains(.subtypes))
        XCTAssertFalse(cases.contains(.clinical))
        XCTAssertFalse(cases.contains(.bedside))
        XCTAssertFalse(cases.map(\.title).contains("患者浏览"))
    }

    func testResearchDesignUsesRecommendedHistoryMiniChartColumns() {
        XCTAssertEqual(ResearchWorkspaceDesignContract.historicalMiniChartColumns, 2)
    }

    func testVisualProductionContractConstants() {
        XCTAssertEqual(ResearchWorkspaceDesignContract.overviewProductionSignalCount, 4)
        XCTAssertEqual(
            ResearchWorkspaceDesignContract.riskVisualizationFamilies,
            ["triageStack", "phenotypeBars", "wardMatrix"]
        )
    }

    func testBrandVersionMetadata() {
        XCTAssertEqual(AppBrand.productName, "sepsiscare")
        XCTAssertEqual(AppBrand.version, "1.0.1")
        XCTAssertEqual(AppBrand.releaseName, "Production Remote Training")
        XCTAssertEqual(AppBrand.bundleIdentifier, "care.sepsis.desktop")
        XCTAssertFalse(AppBrand.build.isEmpty)
    }

    func testBrandPackagingResourcesBundled() {
        XCTAssertNotNil(AppBrand.brandManifestURL)
        XCTAssertNotNil(AppBrand.logoSVGURL)
    }

    func testBrandColorRolesCoverClinicalVisualizationSemantics() {
        let roleIDs = Set(AppBrand.colorRoles.map(\.id))

        XCTAssertTrue(roleIDs.isSuperset(of: [
            "neutralContext",
            "primaryAction",
            "comparison",
            "warning",
            "critical",
            "recovery",
            "family",
            "admin"
        ]))
        XCTAssertEqual(AppBrand.colorRoles.count, 8)
        XCTAssertTrue(AppBrand.colorRoles.allSatisfy { !$0.label.isEmpty && !$0.usage.isEmpty })
    }

    func testSettingsNormalizeRemoteAPIBaseURLForPersistenceAndLocalDetection() {
        UserDefaults.standard.set("  http://10.15.85.223:8765/  ", forKey: "sepsis.apiBaseURL")
        let loadedSettings = AppSettings()
        XCTAssertEqual(loadedSettings.apiBaseURL, "http://10.15.85.223:8765")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sepsis.apiBaseURL"), "http://10.15.85.223:8765")
        XCTAssertFalse(loadedSettings.usesLocalAPIBaseURL)

        UserDefaults.standard.removeObject(forKey: "sepsis.apiBaseURL")
        let settings = AppSettings()

        settings.apiBaseURL = "  http://10.15.85.223:8765/  "

        XCTAssertEqual(settings.apiBaseURL, "http://10.15.85.223:8765")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sepsis.apiBaseURL"), "http://10.15.85.223:8765")
        XCTAssertFalse(settings.usesLocalAPIBaseURL)

        settings.apiBaseURL = "   "

        XCTAssertEqual(settings.apiBaseURL, SepsisCareAPI.defaultBaseURL)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sepsis.apiBaseURL"), SepsisCareAPI.defaultBaseURL)
        XCTAssertTrue(settings.usesLocalAPIBaseURL)
    }

    func testSettingsPreservesLocalAndMigratesLegacyCloudAPIBaseURLsToLocalDefault() {
        UserDefaults.standard.set("http://127.0.0.1:8765", forKey: "sepsis.apiBaseURL")
        var settings = AppSettings()
        XCTAssertEqual(settings.apiBaseURL, SepsisCareAPI.defaultBaseURL)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sepsis.apiBaseURL"), SepsisCareAPI.defaultBaseURL)
        XCTAssertTrue(settings.usesLocalAPIBaseURL)

        UserDefaults.standard.set("http://100.65.136.96:8788", forKey: "sepsis.apiBaseURL")
        settings = AppSettings()
        XCTAssertEqual(settings.apiBaseURL, SepsisCareAPI.defaultBaseURL)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sepsis.apiBaseURL"), SepsisCareAPI.defaultBaseURL)
        XCTAssertTrue(settings.usesLocalAPIBaseURL)

        UserDefaults.standard.set("http://106.55.230.127", forKey: "sepsis.apiBaseURL")
        settings = AppSettings()
        XCTAssertEqual(settings.apiBaseURL, SepsisCareAPI.defaultBaseURL)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sepsis.apiBaseURL"), SepsisCareAPI.defaultBaseURL)
        XCTAssertTrue(settings.usesLocalAPIBaseURL)
    }

    func testSettingsNormalizeBareIPv6APIBaseURL() {
        UserDefaults.standard.set("  http://fd00::20:8765/  ", forKey: "sepsis.apiBaseURL")

        let loadedSettings = AppSettings()

        XCTAssertEqual(loadedSettings.apiBaseURL, "http://[fd00::20]:8765")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sepsis.apiBaseURL"), "http://[fd00::20]:8765")
        XCTAssertEqual(
            SepsisCareHealthProbe.healthURL(for: loadedSettings.apiBaseURL)?.absoluteString,
            "http://[fd00::20]:8765/health"
        )
    }

    func testAPIClientNormalizesBaseURLBeforeBuildingRequests() async {
        let client = APIClient.shared

        await client.setBaseURL("  http://10.15.85.223:8765/  ")

        let remoteBaseURL = await client.baseURL
        XCTAssertEqual(remoteBaseURL, "http://10.15.85.223:8765")

        await client.setBaseURL("   ")

        let defaultBaseURL = await client.baseURL
        XCTAssertEqual(defaultBaseURL, SepsisCareAPI.defaultBaseURL)
    }

    func testBackendControllerNormalizesBaseURLForHealthChecks() {
        let backend = BackendController(autoStart: false)

        backend.setAPIBaseURL("  http://10.15.85.223:8765/  ")

        XCTAssertEqual(backend.apiBaseURL, "http://10.15.85.223:8765")

        backend.setAPIBaseURL("   ")

        XCTAssertEqual(backend.apiBaseURL, SepsisCareAPI.defaultBaseURL)
    }

    func testHealthProbeBuildsStrictHealthURLs() {
        XCTAssertEqual(
            SepsisCareHealthProbe.healthURL(for: "  http://10.15.85.223:8765/  ")?.absoluteString,
            "http://10.15.85.223:8765/health"
        )
        XCTAssertNil(SepsisCareHealthProbe.healthURL(for: "http://"))
        XCTAssertNil(SepsisCareHealthProbe.healthURL(for: "not a url"))
    }

    func testHealthProbeAcceptsOnlyCompatibleBackendPayload() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:8765/health"))
        let okResponse = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let okPayload = Data(#"{"status":"ok","service":"sepsis","history_patients":120,"data_dir":"/tmp"}"#.utf8)

        XCTAssertTrue(SepsisCareHealthProbe.isCompatibleHealthResponse(data: okPayload, response: okResponse))

        let modelServicePayload = Data(#"{"ok":true,"status":"ok","service":"sepsiscare-model-service","model_id":"s7_phenotype_contrastive_full_20260516","missing":[],"history_patients":12135}"#.utf8)
        XCTAssertTrue(SepsisCareHealthProbe.isCompatibleHealthResponse(data: modelServicePayload, response: okResponse))

        let wrongPayload = Data(#"{"status":"ok","service":"other"}"#.utf8)
        XCTAssertFalse(SepsisCareHealthProbe.isCompatibleHealthResponse(data: wrongPayload, response: okResponse))
    }

    func testBackendControllerCheckHealthNowMarksInvalidURLDisconnected() async {
        let backend = BackendController(autoStart: false)
        backend.isReady = true
        backend.setAPIBaseURL("http://")

        let result = await backend.checkHealthNow()

        XCTAssertFalse(result.isOnline)
        XCTAssertFalse(backend.isReady)
        XCTAssertEqual(backend.statusText, "API 地址无效")
        XCTAssertTrue(result.detail.contains("http://"))
    }

    func testAppQuitsAfterLastWindowCloses() {
        let delegate = SepsisCareAppDelegate()

        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
