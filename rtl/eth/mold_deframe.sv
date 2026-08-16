`default_nettype none

module mold_deframe #(
    parameter int IN_BYTES = 8
) (
    input wire logic clk,
    input wire logic rst,
    input wire logic in_valid,
    input wire logic [8*IN_BYTES-1:0] in_data,
    input wire logic [IN_BYTES-1:0] in_keep,
    input wire logic in_last,
    input wire logic in_fcs_ok,
    output logic msg_valid,
    output logic [16*IN_BYTES-1:0] msg_data,
    output logic [2*IN_BYTES-1:0] msg_keep,
    output logic msg_start,
    output logic msg_last,
    output logic [15:0] msg_len, // message length is 2 bytes
    output logic [63:0] msg_seq, // message sequence is 8 bytes
    output logic pkt_bad, // in_fcs_ok = 0
    output logic gap_pulse, // packets were lost before this one
    output logic [63:0] gap_from, // first sequence number missed
    output logic [15:0] gap_count, // messages missed, saturating
    output logic dup_pulse // packet older than expected
);

    // MoldUDP64: session[10] seq[8] count[2] then count x { len[2] body[len] }

    localparam int LANES = IN_BYTES;
    localparam int LANE_W = $clog2(LANES);
    localparam int CNT_W = $clog2(LANES + 1);
    localparam int BEAT_W = 16 - LANE_W;
    localparam int STAGE_W = 8 * (LANES - 1);
    localparam int MSG_W = 16 * LANES;
    localparam logic [CNT_W-1:0] ALL_LANES = CNT_W'(LANES);
    localparam logic [BEAT_W-1:0] HDR_BEATS = BEAT_W'((20 - 1) / LANES);
    localparam logic [CNT_W-1:0] HDR_TAIL = CNT_W'(((20 - 1) % LANES) + 1);
    localparam logic HDR_ENDS = (HDR_BEATS == 0);
    localparam logic [CNT_W-1:0] HDR_LANES = HDR_ENDS ? HDR_TAIL : ALL_LANES;
    localparam logic [2*LANES-1:0] KEEP_ONES = {(2*LANES){1'b1}};
    localparam int SEQ_END_BEAT = 17 / LANES; // beat carrying the last sequence byte

    logic [CNT_W-1:0] run_lanes, run_lanes_next; // lanes of this beat inside the current run
    logic [CNT_W-1:0] tail_lanes, tail_lanes_next; // lanes the run's final beat will carry
    logic [CNT_W-1:0] stage_bytes, stage_bytes_next; // bytes held in stage from the previous beat
    logic [BEAT_W-1:0] beats_left, beats_left_next; // beats of the run left after this one
    logic run_ends, run_ends_next; // the run finishes inside this beat
    logic in_hdr, in_hdr_next; // the run is the 20-byte header
    logic len_split, len_split_next; // the length high byte was the last lane
    logic msg_first, msg_first_next; // msg_start
    logic [7:0] len_high, len_high_next;
    logic [STAGE_W-1:0] stage, stage_next;
    logic [15:0] len, len_next;
    logic [63:0] seq, seq_next;
    logic [2:0] hdr_beat, hdr_beat_next;

    logic [63:0] expect_seq; // sequence the next packet should announce
    logic [63:0] seen_seq, hold_expect; // the pair under comparison, both registered
    logic [63:0] seq_delta;
    logic primed, seq_done, cmp_valid;

    assign pkt_bad = in_valid & in_last & ~in_fcs_ok;

    assign seq_done = in_valid & in_hdr & (hdr_beat == 3'(SEQ_END_BEAT));
    assign seq_delta = seen_seq - hold_expect;

    always_comb begin
        logic [CNT_W-1:0] skip_bytes, lead_bytes;
        logic [LANE_W-1:0] tail_low;
        logic borrow, len_ready, last_beat;
        logic [2*LANES-1:0] keep_mask;
        logic [15:0] len_bytes;
        logic [15:0] next_len;

        msg_valid = in_valid & ~in_hdr & (run_lanes != '0);
        msg_last = msg_valid & run_ends;
        msg_start = msg_valid & msg_first;
        msg_len = len;
        msg_seq = seq;
        msg_data = (MSG_W'(in_data) << (8 * stage_bytes)) | MSG_W'(stage); // residue first, then
        keep_mask = ((((2*LANES)'(in_keep)) & ~(KEEP_ONES << run_lanes)) << stage_bytes)
                  | ~(KEEP_ONES << stage_bytes); // this beat's own bytes
        msg_keep = {(2*LANES){msg_valid}} & keep_mask;

        skip_bytes = len_split ? ALL_LANES : (ALL_LANES - 1 - run_lanes); // length bytes still to come
        lead_bytes = skip_bytes - 1; // bytes of the next run that land in this beat
        len_ready = run_ends & (len_split | (run_lanes <= ALL_LANES - 2));
        last_beat = (beats_left == 1);

        len_bytes = 16'(in_data >> (8 * run_lanes));
        next_len = len_split ? {len_high, in_data[7:0]} : {len_bytes[7:0], len_bytes[15:8]};

        // next_len - lead_bytes bytes start next beat, so the run spans (rem-1)/LANES + 1
        // beats and its last beat carries (rem-1)%LANES + 1 of them. LANES is a power of
        // two, so both are slices of next_len - skip_bytes and only LANE_W bits subtract.
        tail_low = next_len[LANE_W-1:0] - skip_bytes[LANE_W-1:0];
        borrow = {1'b0, next_len[LANE_W-1:0]} < skip_bytes;

        run_lanes_next = run_lanes; // default everything to unchanged
        tail_lanes_next = tail_lanes;
        beats_left_next = beats_left;
        run_ends_next = run_ends;
        in_hdr_next = in_hdr;
        len_split_next = len_split;
        len_high_next = len_high;
        stage_bytes_next = stage_bytes;
        stage_next = stage;
        len_next = len;
        seq_next = seq;
        msg_first_next = msg_first;
        hdr_beat_next = hdr_beat;

        if (in_valid) begin
            for (int k = 0; k < 8; k++) // the 8 sequence bytes sit at fixed
                if (in_hdr && hdr_beat == 3'((10 + k) / LANES)) // lanes of fixed header beats
                    seq_next[8*(7 - k) +: 8] = in_data[8*((10 + k) % LANES) +: 8];
            if (in_hdr) hdr_beat_next = hdr_beat + 3'd1;
            if (msg_valid) msg_first_next = 1'b0;
            stage_bytes_next = '0;
            stage_next = '0;

            if (!run_ends) begin
                beats_left_next = beats_left - 1'b1;
                run_ends_next = last_beat;
                run_lanes_next = last_beat ? tail_lanes : ALL_LANES;
            end else begin
                if (msg_last) seq_next = seq + 64'd1;
                in_hdr_next = 1'b0;
                msg_first_next = 1'b1;
                len_split_next = 1'b0;
                beats_left_next = '0;
                run_ends_next = 1'b1;
                run_lanes_next = '0;
                if (len_ready) begin
                    len_next = next_len;
                    stage_bytes_next = lead_bytes;
                    stage_next = STAGE_W'(in_data >> (8 * (LANES - int'(lead_bytes))));
                    tail_lanes_next = CNT_W'(tail_low) + 1'b1;
                    beats_left_next = next_len[15:LANE_W] - BEAT_W'(borrow);
                    run_ends_next = (next_len[15:LANE_W+1] == '0) & (next_len[LANE_W] == borrow);
                    run_lanes_next = run_ends_next ? tail_lanes_next : ALL_LANES;
                end else if (run_lanes == ALL_LANES - 1) begin
                    len_high_next = in_data[8*(LANES-1) +: 8];
                    len_split_next = 1'b1;
                end
            end

            if (in_last) begin
                in_hdr_next = 1'b1;
                len_split_next = 1'b0;
                run_lanes_next = HDR_LANES;
                run_ends_next = HDR_ENDS;
                beats_left_next = HDR_BEATS;
                tail_lanes_next = HDR_TAIL;
                stage_bytes_next = '0;
                msg_first_next = 1'b1;
                hdr_beat_next = '0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            run_lanes <= HDR_LANES;
            run_ends <= HDR_ENDS;
            beats_left <= HDR_BEATS;
            tail_lanes <= HDR_TAIL;
            in_hdr <= 1'b1;
            len_split <= 1'b0;
            stage_bytes <= '0;
            msg_first <= 1'b1;
            hdr_beat <= '0;
        end else begin
            run_lanes <= run_lanes_next;
            run_ends <= run_ends_next;
            beats_left <= beats_left_next;
            tail_lanes <= tail_lanes_next;
            in_hdr <= in_hdr_next;
            len_split <= len_split_next;
            stage_bytes <= stage_bytes_next;
            msg_first <= msg_first_next;
            hdr_beat <= hdr_beat_next;
        end
        len_high <= len_high_next;
        stage <= stage_next;
        len <= len_next;
        seq <= seq_next;
    end

    // seq counts messages, so by the end of a packet it already holds the sequence
    // the next packet should announce. Comparing the two catches loss and replay.
    // Both operands are captured on the header beat and compared the cycle after,
    // keeping the 64-bit subtract register to register. The snapshot also fixes the
    // ordering on a count-0 heartbeat, where the header beat is also the last beat
    // and expect_seq is reloaded from the same value being tested.

    always_ff @(posedge clk) begin
        if (rst) begin
            primed <= 1'b0;
            cmp_valid <= 1'b0;
            gap_pulse <= 1'b0;
            dup_pulse <= 1'b0;
        end else begin
            cmp_valid <= seq_done;
            if (cmp_valid) primed <= 1'b1;
            gap_pulse <= primed & cmp_valid & (seen_seq > hold_expect);
            dup_pulse <= primed & cmp_valid & (seen_seq < hold_expect);
        end
        if (seq_done) begin
            seen_seq <= seq_next;
            hold_expect <= expect_seq;
        end
        if (cmp_valid) begin
            gap_from <= hold_expect;
            gap_count <= (|seq_delta[63:16]) ? 16'hFFFF : seq_delta[15:0];
        end
        if (in_valid & in_last) expect_seq <= seq_next;
    end

endmodule

`default_nettype wire
