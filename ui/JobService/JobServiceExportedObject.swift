import Foundation
import DBRepository
import ServiceContracts

final class JobServiceExportedObject: NSObject, JobServiceXPC {
    func health(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            await JobServiceStore.shared.log(level: .debug, message: "health requested", code: "health")
            let path = await JobServiceStore.shared.databasePath()
            let leaf = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
            let report = ServiceHealthReport(
                service: .job,
                status: .ok,
                detail: "JobService ready (DB+\(leaf))"
            )
            let data = (try? JobServiceXPCCodec.encodeHealth(report)) ?? Data("{}".utf8)
            reply(data as NSData)
        }
    }

    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void) {
        Task {
            do {
                let repo = try await JobServiceStore.shared.sharedRepository()
                let path = await repo.databaseURL.path
                try await repo.appendServiceLog(
                    ServiceLogEntry(
                        service: DerrickServiceID.job.shortName,
                        level: .info,
                        code: "bootstrap",
                        message: "JobService bootstrap complete",
                        detailJSON: #"{"database":"\#(path)"}"#
                    )
                )
                JobServiceScheduler.shared.start()
                let result = JobServiceBootstrapResult(ok: true, databasePath: path, message: "ok")
                reply((try JobServiceXPCCodec.encodeBootstrap(result)) as NSData)
            } catch {
                await JobServiceStore.shared.log(
                    level: .error,
                    message: "bootstrap failed: \(error.localizedDescription)",
                    code: "bootstrap_failed"
                )
                let result = JobServiceBootstrapResult(
                    ok: false,
                    databasePath: nil,
                    message: error.localizedDescription
                )
                reply((try? JobServiceXPCCodec.encodeBootstrap(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }

    func createJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try JobServiceXPCCodec.decodeSignedCreateJobRequest(data)
                let job = try await JobServiceHost.shared.createJob(request)
                let result = CreateJobResult(ok: true, job: job, message: "ok")
                reply((try JobServiceXPCCodec.encodeCreateJobResult(result)) as NSData)
            } catch {
                fputs("[JobService] createJob failed: \(error.localizedDescription)\n", stderr)
                let result = CreateJobResult(ok: false, message: error.localizedDescription)
                reply((try? JobServiceXPCCodec.encodeCreateJobResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }

    func cancelJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try JobServiceXPCCodec.decodeSignedCancelJob(data)
                try await JobServiceHost.shared.cancelJob(jobID: request.jobID)
                let ack = try JobServiceXPCCodec.encodeSignedAck(.ok, to: .ui)
                reply(ack as NSData)
            } catch {
                let ack = (try? JobServiceXPCCodec.encodeSignedAck(.error(error.localizedDescription), to: .ui))
                    ?? Data()
                reply(ack as NSData)
            }
        }
    }

    func getJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try JobServiceXPCCodec.decodeSignedGetJob(data)
                let job = try await JobServiceHost.shared.getJob(jobID: request.jobID)
                let result = CreateJobResult(ok: true, job: job, message: "ok")
                reply((try JobServiceXPCCodec.encodeCreateJobResult(result)) as NSData)
            } catch {
                let result = CreateJobResult(ok: false, message: error.localizedDescription)
                reply((try? JobServiceXPCCodec.encodeCreateJobResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }

    func listJobs(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try JobServiceXPCCodec.decodeSignedListJobs(data)
                let jobs = try await JobServiceHost.shared.listJobs(request: request)
                let result = ListJobsResult(ok: true, jobs: jobs, message: "ok")
                reply((try JobServiceXPCCodec.encodeListJobsResult(result)) as NSData)
            } catch {
                let result = ListJobsResult(ok: false, message: error.localizedDescription)
                reply((try? JobServiceXPCCodec.encodeListJobsResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }

    // MARK: - Schedules

    func createSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try JobServiceXPCCodec.decodeSignedCreateSchedule(data)
                let schedule = try await JobServiceHost.shared.createSchedule(request)
                let result = ScheduleResult(ok: true, schedule: schedule, message: "ok")
                reply((try JobServiceXPCCodec.encodeScheduleResult(result)) as NSData)
            } catch {
                fputs("[JobService] createSchedule failed: \(error.localizedDescription)\n", stderr)
                let result = ScheduleResult(ok: false, message: error.localizedDescription)
                reply((try? JobServiceXPCCodec.encodeScheduleResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }

    func updateSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try JobServiceXPCCodec.decodeSignedUpdateSchedule(data)
                let schedule = try await JobServiceHost.shared.updateSchedule(request)
                let result = ScheduleResult(ok: true, schedule: schedule, message: "ok")
                reply((try JobServiceXPCCodec.encodeScheduleResult(result)) as NSData)
            } catch {
                fputs("[JobService] updateSchedule failed: \(error.localizedDescription)\n", stderr)
                let result = ScheduleResult(ok: false, message: error.localizedDescription)
                reply((try? JobServiceXPCCodec.encodeScheduleResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }

    func setScheduleEnabled(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try JobServiceXPCCodec.decodeSignedSetScheduleEnabled(data)
                let schedule = try await JobServiceHost.shared.setScheduleEnabled(
                    scheduleID: request.scheduleID,
                    enabled: request.enabled
                )
                let result = ScheduleResult(ok: true, schedule: schedule, message: "ok")
                reply((try JobServiceXPCCodec.encodeScheduleResult(result)) as NSData)
            } catch {
                fputs("[JobService] setScheduleEnabled failed: \(error.localizedDescription)\n", stderr)
                let result = ScheduleResult(ok: false, message: error.localizedDescription)
                reply((try? JobServiceXPCCodec.encodeScheduleResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }

    func deleteSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try JobServiceXPCCodec.decodeSignedDeleteSchedule(data)
                try await JobServiceHost.shared.deleteSchedule(scheduleID: request.scheduleID)
                let ack = try JobServiceXPCCodec.encodeSignedAck(.ok, to: .ui)
                reply(ack as NSData)
            } catch {
                let ack = (try? JobServiceXPCCodec.encodeSignedAck(.error(error.localizedDescription), to: .ui))
                    ?? Data()
                reply(ack as NSData)
            }
        }
    }

    func getSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try JobServiceXPCCodec.decodeSignedGetSchedule(data)
                let schedule = try await JobServiceHost.shared.getSchedule(scheduleID: request.scheduleID)
                let result = ScheduleResult(ok: true, schedule: schedule, message: "ok")
                reply((try JobServiceXPCCodec.encodeScheduleResult(result)) as NSData)
            } catch {
                let result = ScheduleResult(ok: false, message: error.localizedDescription)
                reply((try? JobServiceXPCCodec.encodeScheduleResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }

    func listSchedules(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let data = requestJSON as Data
        Task {
            do {
                let request = try JobServiceXPCCodec.decodeSignedListSchedules(data)
                let schedules = try await JobServiceHost.shared.listSchedules(request: request)
                let result = ListSchedulesResult(ok: true, schedules: schedules, message: "ok")
                reply((try JobServiceXPCCodec.encodeListSchedulesResult(result)) as NSData)
            } catch {
                let result = ListSchedulesResult(ok: false, message: error.localizedDescription)
                reply((try? JobServiceXPCCodec.encodeListSchedulesResult(result)) as NSData? ?? Data("{}".utf8) as NSData)
            }
        }
    }
}
