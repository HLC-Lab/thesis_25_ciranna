1. Esegui runTopology.sh per settare i parametri con i quali TECCL costruisce il modello della rete. 
   Inseguito verrà lanciato il solver di GUROBI per generare lo schedule. 

conda activate te-ccl-env


./runTopology.sh ./teccl/inputs/dragonflyPlus_input.json num_groups 2 spine_routers 2 leaf_routers 1 hosts_per_router 2 chunk_size 0.05  alpha '[1.0, 10.0]' heuristics 0.95   collective 1   time_limit 600 feasibility_tol 0.0001   intfeas_tol 0.0001   optimality_tol 0.0001   output_flag 0   log_file ""   log_to_console 1 mip_gap 0.001   mip_focus 1   crossover -1   method -1   num_chunks 3   epoch_type 2   epoch_duration 20000 num_epochs 10   alpha_threshold 0.1   switch_copy false   debug false   debug_output_file ""   objective_type 3 solution_method 2   schedule_output_file "teccl/schedules/dragonflyPlus_schedule.json"

./run.sh ./teccl/inputs/dragonflyPlus_input.json num_groups 2 spine_routers 4 leaf_routers 4 hosts_per_router 4 chunk_size 0.000008  alpha '[1.0, 10.0]' heuristics 0.95   collective 1   time_limit 600 feasibility_tol 0.0001   intfeas_tol 0.0001   optimality_tol 0.0001   output_flag 0   log_file ""   log_to_console 1 mip_gap 0.001   mip_focus 1   crossover -1   method -1   num_chunks 3   epoch_type 2   epoch_duration 20000 num_epochs 10   alpha_threshold 0.1   switch_copy false   debug false   debug_output_file ""   objective_type 1 solution_method 2   schedule_output_file "teccl/schedules_teccl/dragonflyPlus_schedule.json"

./run_topology.sh ./teccl/inputs/dragonflyPlus_input.json num_groups 2 spine_routers 2 leaf_routers 1 hosts_per_router 2 chunk_size 0.00008  alpha '[1.0, 10.0]' heuristics 0.95   collective 1   time_limit 600 feasibility_tol 0.0001   intfeas_tol 0.0001   optimality_tol 0.0001   output_flag 0   log_file ""   log_to_console 1 mip_gap 0.001   mip_focus 1   crossover -1   method -1   num_chunks 1   epoch_type 2   epoch_duration 20000 num_epochs 10   alpha_threshold 0.1   switch_copy false   debug false   debug_output_file ""   objective_type 1 solution_method 2   schedule_output_file "teccl/schedules/dragonflyPlus_schedule.json"



2. Esegui la funzione simulateAllSchedule per simulare lo schedule generato da TECCL utilizzando operazioni di invio e 
   ricezione point-to-point, al fine di confrontare il risultato con quello della collettiva MPI_Allgather e verificare 
   che siano equivalenti.

mpicc -O2 -Wall -Wextra -DDEBUG_SIM   -o simulateAllSchedule simulateAllSchedule.c ../cJSON/cJSON.c -I../cJSON

mpirun --oversubscribe -np 4 ./simulateAllSchedule ./teccl/inputs/dragonflyPlus_input.json ./teccl/schedules/dragonflyPlus_schedule.json


3. Esegui convertTecclSchedule per convertire lo schdedule generato da TECCL in un formato leggibile dal simulatore HTSIM.

./convertTecclSchedule ./teccl/inputs/dragonflyPlus_input.json ./teccl/schedules/dragonflyPlus_schedule.json ./teccl/converts/dragonflyPlus_schedule.cm


4. Esegui htsim_ndp.

../csg-htsim/sim/datacenter/htsim_ndp -nodes 8 -tm teccl/converts/dragonflyPlus_schedule.cm -tiers 2 -cwnd 50 -strat perm -log sink -q 50 -end 1000
-strat perm -log sink -q 50 -end 1000

../csg-htsim/sim/datacenter/htsim_roce -tm ./teccl/converts/dragonflyPlus_schedule.cm -nodes 4 -strat minimal -end 100000 -type Df+

../csg-htsim/sim/datacenter/htsim_roce  -tm ./teccl/converts/dragonflyPlus_schedule.cm  -nodes 4  -strat minimal  -type Df+  -end 100000  -log 

../csg-htsim/sim/datacenter/htsim_roce -tm ./teccl/converts/dragonflyPlus_schedule.cm  -type Df+  -nodes 4 -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1.0



5. analisi dei ricultati

python3 parse_runlog.py run.log --time-unit ms --out-csv flows_parsed.csv --out-summary summary.txt
python3 parse.py run.log --unit-startis us --unit-finish s --out-csv flows_parsed.csv   --out-summary summary.txt

python3 parse.py run.log --unit-finish s --unit-startis us --out-csv flows_parsed.csv --out-summary summary.txt --plots-dir plots --plots hist,cdf,scatter,gantt --hist-bins 40 --gantt-max-flows 200

python3 ./parse_runlog.py   run.log   --cmfile ./teccl/converts/dragonflyPlus_schedule.cm   --unit-finish s   --unit-startis us   --out-csv out/flows_with_deps.csv   --out-summary out/summary.txt   --out-dot out/deps.dot   --plots-dir out/plots   --gantt-max-flows 200

python3 ./parse_runlog.py   run.log   --cmfile ./teccl/converts/dragonflyPlus_schedule.cm  --n-hosts 4 --num-chunks 1 --chunk-size-byte 80000 --unit-finish s   --unit-startis us   --out-csv out/flows_with_deps.csv   --out-summary out/summary.txt   --out-dot out/deps.dot   --plots-dir out/plots   --gantt-max-flows 200


./run.sh ./teccl/inputs/dragonflyPlus_input.json   num_groups 2 spine_routers 2 leaf_routers 1 hosts_per_router 2   chunk_size 0.000008 alpha '[1.0, 10.0]' heuristics 0.95 collective 1   schedule_output_file 'teccl/schedules_teccl/dragonflyPlus_schedule.json'   --htsim ../csg-htsim/sim/datacenter/htsim_roce   -type Df+ -nodes 4 -linkspeed 200000000 -mtu 9000   -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input   -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal   -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1.0   --parser python3 ./parse_runlog.py   --unit-finish s --unit-startis us   --out-csv out/flows_with_deps.csv   --out-summary out/summary.txt   --out-dot out/deps.dot   --plots-dir out/plots   --gantt-max-flows 200



6. questo comando lancia la creazione dello schdule MPI fatta da simone

python3 gen_allgather_ring.py teccl/schedules_mpi/prova.cm 16 16 90000 0


7. comando per attivare conda su cluster leonardo
cd /leonardo_work/IscrC_ASCEND_0/fciranna/conda
eval "$(/leonardo_work/IscrC_ASCEND_0/fciranna/conda/miniconda3/bin/conda shell.bash hook)"
conda activate te-ccl-env





comando finale -----

./run_pipeline.sh   num_groups 2 spine_routers 1 leaf_routers 2 hosts_per_router 2   chunk_size 0.05 alpha '[1.0, 10.0]' heuristics 0.95 collective 1   time_limit 600 feasibility_tol 0.0001 intfeas_tol 0.0001 optimality_tol 0.0001   output_flag 0 log_file "" log_to_console 1 mip_gap 0.001 mip_focus 1   crossover -1 method -1 num_chunks 1 epoch_type 2 epoch_duration 20000   num_epochs 10 alpha_threshold 0.1 switch_copy false debug false   debug_output_file "" objective_type 1 solution_method 2   --convert ./convertTecclSchedule   --htsim ../csg-htsim/sim/datacenter/htsim_roce     -type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05     -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64     -strat minimal -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1.0   --parser python3 ./parse_runlog.py     --unit-finish s --unit-startis us --gantt-max-flows 200

./sweep_pipeline.sh 32  chunk_size 0.05  alpha '[1.0, 10.0]' heuristics 0.95   collective 1   time_limit 600 feasibility_tol 0.0001   intfeas_tol 0.0001   optimality_tol 0.0001   output_flag 0   log_file ""   log_to_console 1 mip_gap 0.001   mip_focus 1   crossover -1   method -1   num_chunks 1   epoch_type 2   epoch_duration 20000 num_epochs 10   alpha_threshold 0.1   switch_copy false   debug false   debug_output_file ""  --convert ./convertTecclSchedule   --htsim ../csg-htsim/sim/datacenter/htsim_roce     -type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05     -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64     -strat minimal -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1.0   --parser python3 ./parse_runlog.py     --unit-finish s --unit-startis us --gantt-max-flows 200

./sweep_pipeline.sh 32 chunk_size 0.000008 alpha '[1.0, 10.0]' heuristics 0.95 collective 1 --convert ./convertTecclSchedule --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1.0 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us --gantt-max-flows 200

./run_mpi_pipeline.sh --gen ./gen_allgather_ring.py --n 16 --p4 90000 --p5 0 --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us

./sweep_pipeline.sh 32 chunk_size 0.000008 alpha '[1.0, 10.0]' heuristics 0.95 collective 1 --convert ./convertTecclSchedule --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1.0 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us --gantt-max-flows 200 --mpi-gen ./gen_allgather_ring.py --mpi-p4 90000 --mpi-p5 0

./sweep_pipeline.sh 32 chunk_size 0.000004 alpha '[1.0, 10.0]' heuristics 0.95 collective 1 num_chunks 1 --convert ./convertTecclSchedule --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1.0 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us --gantt-max-flows 200 --mpi-gen ./gen_allgather_ring.py --mpi-p4 90000 --mpi-p5 0

./sweep_pipeline.sh 32 1 chunk_size 0.007 alpha '[1.0, 10.0]' heuristics 0.95 collective 1 --convert ./convertTecclSchedule --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1.0 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us --gantt-max-flows 200 --mpi-gen ./gen_allgather_ring.py --mpi-p5 0

------------------------------------------------------------------------------------------

./run_pipeline.sh   --topology ./run_topology.sh   num_groups 2 leaf_routers 1 spine_routers 1 hosts_per_router 8   num_chunks 3 chunk_size 0.007   alpha '[1.0, 10.0]' heuristics 0.95 collective 1   --convert ./convertTecclSchedule   --htsim ../csg-htsim/sim/datacenter/htsim_roce     -type Df+ -linkspeed 200000000 -mtu 9000     -hop_latency 1 -switch_latency 0.05     -queue_type lossless_input -q 64     -pfc_thresholds 12 15 -threshold 64     -strat minimal -start_delta 200000 -end 800000     -log sink -log traffic -logtime 1.0   --parser python3 ./parse_runlog.py     --unit-finish s --unit-startis us --gantt-max-flows 200


./run_mpi_pipeline.sh --gen ./gen_allgather_ring.py --n 16 --p4 90000 --p5 0 --chunks 1 --chunk-size-gb 0.00875  --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us

./sweep_pipeline.sh   max_hosts 32   max_chunk_size 0.007   alpha '[1.0, 10.0]' heuristics 0.95 collective 1   --convert ./convertTecclSchedule   --htsim ../csg-htsim/sim/datacenter/htsim_roce     -type Df+ -linkspeed 200000000 -mtu 9000     -hop_latency 1 -switch_latency 0.05     -queue_type lossless_input -q 64     -pfc_thresholds 12 15 -threshold 64     -strat minimal -start_delta 200000 -end 800000   --parser python3 ./parse_runlog.py     --unit-finish s --unit-startis us --gantt-max-flows 200   --mpi-gen ./gen_allgather_ring.py   --mpi-p5 0

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

./run_pipeline.sh --topology ./run_topology.sh -num_groups 2 -leaf_routers 1 -spine_routers 1 -hosts_per_router 8 -num_chunks 1 -chunk_size 0.007 --convert ./convertTecclSchedule --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us --gantt-max-flows 200

./sweep_pipeline.sh --topology ./run_topology.sh -max_hosts 32 -max_chunk_size 0.007 -alpha '[1.0, 10.0]' -heuristics 0.95 -collective 1 -epoch_duration 200 --convert ./convertTecclSchedule --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us --mpi-gen ./gen_allgather_ring.py --mpi-p5 0

./sweep_pipeline.sh --topology ./run_topology.sh max_hosts 32 min_hosts 24 -alpha '[1.0, 10.0]' -heuristics 0.95 -collective 1 -epoch_duration 200 --convert ./convertTecclSchedule --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 200000000 -mtu 75000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us --mpi-gen ../simone-htsim/

./sweep_pipeline.sh --topology ./run_topology.sh min_radix 4 max_radix 6 min_groups 2 max_groups 2 -alpha '[1.0, 10.0]' -heuristics 0.95 -collective 1 -epoch_duration 200 --convert ./convertTecclSchedule --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 200000000 -mtu 75000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us --mpi-gen ../simone-htsim/

./sweep_pipeline.sh --topology ./run_topology.sh min_radix 4 max_radix 6 min_groups 2 max_groups 2 -alpha '[1.0, 10.0]' -heuristics 0.95 -collective 1 -epoch_duration 200 --convert ./convertTecclSchedule --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 50000000  -mtu 75000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us --mpi-gen ../simone-htsim/

 ./sweep_pipeline.sh --topology ./run_topology.sh min_radix 4 max_radix 6 min_groups 2 max_groups 2 -alpha '[1.0, 10.0]' -heuristics 0.95 -collective 1 -epoch_type 3 -epoch_duration 200 -num_epochs 10 --convert ./convertTecclSchedule --htsim ../csg-htsim/sim/datacenter/htsim_roce -type Df+ -linkspeed 50000000  -mtu 75000 -hop_latency 1 -switch_latency 0.05 -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64 -strat minimal -start_delta 200000 -end 800000 --parser python3 ./parse_runlog.py --unit-finish s --unit-startis us --mpi-gen ../simone-htsim/ 

conda run -n te-ccl-env python3 analyze_solver_time.py --aggregate canonical --canonical-chunk-bytes 1048576

python3 analyze_solver_time.py --root ./output_pipeline --outdir ./solver_times/  --aggregate canonical --canonical-chunk-bytes 1048576

python3 analyze_solver_time.py   --root ./output_pipeline   --outdir ./results_solver_time   --size 8192

python3 analyze_makespan_size.py   --root ./output_pipeline   --outdir ./results_makespan/

python3 analyze_jain_size.py --root ./output_pipeline --outdir ./results_jain/



ssh ciranna_1533717@192.168.0.102