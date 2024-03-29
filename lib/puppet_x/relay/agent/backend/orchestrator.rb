require 'json'
require 'puppet'

require_relative '../../util/http'
require_relative '../model'
require_relative '../job/schedule'
require_relative 'base'

module PuppetX
  module Relay
    module Agent
      module Backend
        class Orchestrator < Base
          # @param orchestrator_api [Util::HTTP::Client]
          def initialize(relay_api, orchestrator_api)
            super(relay_api)
            @orchestrator_api = orchestrator_api
          end

          def exec(run, _state_dir, schedule)
            case run.state.status
            when :pending
              case run
              when Model::Run
                deploy(run, schedule)
              when Model::TaskRun
                task(run, schedule)
              when Model::PlanRun
                plan_run(run, schedule)
              else
                raise NotImplementedError
              end
            else
              case run
              when Model::Run, Model::TaskRun
                check_job_complete(run, schedule)
              when Model::PlanRun
                check_plan_job_complete(run, schedule)
              else
                raise NotImplementedError
              end
            end
          rescue Net::HTTPClientError, Net::HTTPServerException => e
            Puppet.warning(_('Failed to send request to orchestrator API: %{message}, response: %{body}') % {
              message: e.message,
              body: e.response.body,
            })
            begin
              result = JSON.parse(e.response.body)
            rescue JSON::ParserError
              result = { msg: e.response.body }
            end
            new_state = run.state.to_complete(outcome: 'error', run_results: { result: result })
            run.with_state(new_state)
          rescue Net::HTTPError, Net::HTTPRetriableError, Net::HTTPFatalError => e
            Puppet.warning(_('Failed to send request to orchestrator API: %{message}, response: %{body}') % {
              message: e.message,
              body: e.response.body,
            })
            raise
          end

          private

          # @param run [Model::Run]
          # @param schedule [Job::Schedule]
          def deploy(run, schedule)
            payload = {
              environment: run.environment,
              scope: run.scope,
              debug: run.debug,
              trace: run.trace,
              evaltrace: run.evaltrace,
            }
            run.noop ? payload[:noop] = true : payload[:no_noop] = true
            resp = @orchestrator_api.post(
              'command/deploy',
              body: payload,
            )
            resp.value

            data = JSON.parse(resp.body)

            Puppet.info(_('Orchestrator job %{job_id} started for run %{id}') % { job_id: data['job']['name'], id: run.id })

            new_state = run.state.to_in_progress(schedule.next_update_before, job_id: data['job']['name'])
            run.with_state(new_state)
          end

          # @param run [Model::TaskRun]
          # @param schedule [Job::Schedule]
          def task(run, schedule)
            resp = @orchestrator_api.post(
              'command/task',
              body: {
                environment: run.environment,
                scope: run.scope,
                task: run.name,
                params: run.params,
                noop: run.noop,
                targets: run.targets,
              },
            )
            resp.value

            data = JSON.parse(resp.body)

            Puppet.info(_('Orchestrator job %{job_id} started for task run %{id}') % { job_id: data['job']['name'], id: run.id })

            new_state = run.state.to_in_progress(schedule.next_update_before, job_id: data['job']['name'])
            run.with_state(new_state)
          end

          # @param run [Model::PlanRun]
          # @param schedule [Job::Schedule]
          def plan_run(run, schedule)
            resp = @orchestrator_api.post(
              'command/plan_run',
              body: {
                environment: run.environment,
                plan_name: run.name,
                params: run.params,
              },
            )
            resp.value

            data = JSON.parse(resp.body)

            Puppet.info(_('Orchestrator plan job %{job_id} started for plan run %{id}') % { job_id: data['name'], id: run.id })

            new_state = run.state.to_in_progress(schedule.next_update_before, job_id: data['name'])
            run.with_state(new_state)
          end

          # @param run [Model::Stateful]
          # @param schedule [Job::Schedule]
          def check_job_complete(run, schedule)
            resp = @orchestrator_api.get("jobs/#{run.state.job_id}")
            resp.value

            data = JSON.parse(resp.body)

            new_state =
              case data['state']
              when 'finished', 'failed'
                nodes_resp = @orchestrator_api.get("jobs/#{run.state.job_id}/nodes")
                nodes_resp.value

                nodes_data = JSON.parse(nodes_resp.body)

                run_results = data.slice('node_count', 'owner', 'options', 'timestamp', 'started_timestamp', 'finished_timestamp')
                run_results['nodes'] = nodes_data['items']
                Puppet.debug(_('Run %{id} complete with results %{results}') % { id: run.id, results: run_results })

                run.state.to_complete(outcome: data['state'], run_results: run_results)
              else
                run.state.to_in_progress(schedule.next_update_before)
              end

            run.with_state(new_state)
          end

          # @param run [Model::Stateful]
          # @param schedule [Job::Schedule]
          def check_plan_job_complete(run, schedule)
            resp = @orchestrator_api.get("plan_jobs/#{run.state.job_id}")
            resp.value

            data = JSON.parse(resp.body)

            new_state =
              case data['state']
              when 'success', 'failure'
                run_results = data.slice('owner', 'options', 'timestamp', 'created_timestamp', 'finished_timestamp', 'result')
                Puppet.debug(_('Run %{id} complete with results %{results}') % { id: run.id, results: run_results })

                run.state.to_complete(outcome: data['state'], run_results: run_results)
              else
                run.state.to_in_progress(schedule.next_update_before)
              end

            run.with_state(new_state)
          end
        end
      end
    end
  end
end
