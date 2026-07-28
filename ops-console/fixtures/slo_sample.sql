-- 로컬 검증용 **합성** SLO (ASK-Seoul#58) — 실측이 아니다.
--
-- 팀 D1 쓰기가 금지돼 있어 실제 gold_culture_slo_daily 를 가져올 수 없다. 화면 동작을
-- 확인하려면 데이터가 있어야 하므로 14일치를 합성해 둔다. 모든 행에 is_sample=1 이 박혀
-- 있고 UI 는 그걸 읽어 '샘플' 배지를 띄운다 — 이 데이터로 운영 판단을 하면 안 된다.
-- 실적재 경로가 붙으면 이 파일은 지운다.

DELETE FROM _ops_slo;
DELETE FROM _ops_domain;

-- 도메인 등록부 — has_slo 는 실측이다(ASAC-DBT 에서 *_slo_daily 검색: culture 만 존재)
INSERT INTO _ops_domain (domain,label,has_slo,note) VALUES ('culture','문화·행사',1,NULL);
INSERT INTO _ops_domain (domain,label,has_slo,note) VALUES ('citydata','인구·도시',0,'SLO 마트 미보유');
INSERT INTO _ops_domain (domain,label,has_slo,note) VALUES ('transit','대중교통',0,'SLO 마트 미보유');
INSERT INTO _ops_domain (domain,label,has_slo,note) VALUES ('commerce','상권',0,'SLO 마트 미보유');
INSERT INTO _ops_domain (domain,label,has_slo,note) VALUES ('weather','날씨',0,'SLO 마트 미보유');
INSERT INTO _ops_domain (domain,label,has_slo,note) VALUES ('traffic','교통',0,'SLO 마트 미보유');

-- culture 14일치 (합성). 7/22 정기런 실패·7/25 부분 실패를 넣어 화면의 경고 경로를 확인한다
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-15',1,1,99.5,0,0,41900,4.1,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-16',1,1,99.4,0,0,39273,4.4,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-17',1,1,98.6,0,0,42646,4.1,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-18',1,1,99.1,0,0,38925,3.9,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-19',1,1,99.1,0,0,38368,3.2,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-20',1,1,97.0,0,0,38923,3.3,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-21',1,1,96.9,0,0,42491,5.1,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-22',0,1,71.4,2,1,43997,3.1,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-23',1,1,97.2,0,0,39234,2.8,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-24',1,1,96.2,0,0,42396,3.2,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-25',0,0,42.9,4,3,43619,4.0,1,0,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-26',1,1,96.9,0,0,39029,4.0,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-27',1,1,98.6,0,0,42972,3.2,1,1,1);
INSERT INTO _ops_slo (domain,event_date,scheduled_slo_passed,eod_slo_passed,best_coverage_pct,failed_dataset_count,violation_count,total_rows,ingest_duration_min,transform_runs,transform_all_success,is_sample) VALUES ('culture','2026-07-28',1,1,97.0,0,0,38335,5.4,1,1,1);
