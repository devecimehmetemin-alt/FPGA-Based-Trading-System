module tb_frame_unpack();

    localparam int NFRAME = 24;
    localparam int MAXE = 8192;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, in_valid, in_ready, pace_req, pace_grant;
    logic [63:0] in_data;
    logic [31:0] pace_period;
    logic out_valid, out_last, out_ready, frame_pulse, underrun;
    logic [63:0] out_data;
    logic [7:0] out_keep;

    // record stream: a header word carrying length and pacing period, then the
    // frame padded up to a whole number of 64 bit beats
    int f_len [0:NFRAME-1];
    int f_period [0:NFRAME-1];

    logic [63:0] e_data [0:MAXE-1];
    logic [7:0] e_keep [0:MAXE-1];
    bit e_last [0:MAXE-1];
    int n_exp = 0, recv = 0, pulses = 0, errors = 0;

    int gdelay = 0, gcnt = 0;
    bit body_phase = 0;
    bit check_underrun = 1;

    frame_unpack DUT(.*);

    function automatic logic [63:0] word_of(input int f, input int b);
        logic [63:0] w;
        w = '0;
        for (int i = 0; i < 8; i++) begin
            int byte_no;
            byte_no = 8 * b + i;
            if (byte_no < f_len[f]) w[8*i +: 8] = 8'(f * 7 + byte_no + 1);
        end
        return w;
    endfunction

    // the pacer stands in for frame_pacer so the handshake is tested on its own
    always_ff @(posedge clk) begin
        if (rst) begin
            gcnt <= 0;
            pace_grant <= 1'b0;
        end else begin
            pace_grant <= 1'b0;
            if (pace_req && !pace_grant) begin
                if (gcnt >= gdelay) begin
                    pace_grant <= 1'b1;
                    gcnt <= 0;
                end else begin
                    gcnt <= gcnt + 1;
                end
            end else if (!pace_req) begin
                gcnt <= 0;
            end
        end
    end

    task automatic send_word(input logic [63:0] w);
        in_data = w;
        in_valid = 1'b1;
        @(negedge clk);
        while (!in_ready) @(negedge clk);
        @(posedge clk); #1;
    endtask

    task automatic idle_gap(input int n);
        in_valid = 1'b0;
        repeat (n) @(posedge clk);
        #1;
    endtask

    initial begin
        int beats;

        // lengths cover every remainder mod 8, so the tail keep mask is checked
        // in all eight of its forms including the exact multiple
        for (int f = 0; f < NFRAME; f++) begin
            f_len[f] = 8 + f * 9 + (f % 3);
            f_period[f] = 16 + f;
        end

        for (int f = 0; f < NFRAME; f++) begin
            beats = (f_len[f] + 7) / 8;
            for (int b = 0; b < beats; b++) begin
                e_data[n_exp] = word_of(f, b);
                e_keep[n_exp] = (b == beats - 1)
                              ? ((f_len[f] % 8 == 0) ? 8'hFF
                                                     : 8'((8'd1 << (f_len[f] % 8)) - 8'd1))
                              : 8'hFF;
                e_last[n_exp] = (b == beats - 1);
                n_exp++;
            end
        end

        rst = 1; in_valid = 0; in_data = '0; out_ready = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        fork
            begin : producer
                for (int f = 0; f < NFRAME; f++) begin
                    gdelay = f % 4;
                    // gaps belong between frames, never inside one: the pacer is
                    // what buys the read path time to refill
                    idle_gap(f % 5);
                    if (f % 6 == 3) begin
                        // a zero length record is skipping padding at the end of
                        // an extent, consumed with no output and no pacing
                        body_phase = 0;
                        send_word({32'd0, 16'd0, 16'd0});
                    end
                    body_phase = 0;
                    send_word({32'(f_period[f]), 16'd0, 16'(f_len[f])});
                    body_phase = 1;
                    for (int b = 0; b < (f_len[f] + 7) / 8; b++)
                        send_word(word_of(f, b));
                    body_phase = 0;
                end
                in_valid = 1'b0;

                // now the case the sender must never hit in the field: the record
                // path starving in the middle of a body
                check_underrun = 0;
                repeat (4) @(posedge clk);
                #1;
                gdelay = 0;
                f_len[0] = 64;
                send_word({32'd16, 16'd0, 16'd64});
                send_word(64'hDEAD_BEEF_0000_0001);
                in_valid = 1'b0;
                repeat (3) @(posedge clk);
                #1;
                if (!underrun) begin
                    $error("no underrun with the record path starved mid frame");
                    errors++;
                end
            end
            begin : consumer
                while (recv < n_exp) begin
                    @(posedge clk); #1;
                    out_ready = ($urandom_range(0, 9) < 8);
                    @(negedge clk);
                    if (out_valid && out_ready) begin
                        if (out_data !== e_data[recv]) begin
                            if (errors < 10)
                                $error("beat %0d data: got %016h expected %016h",
                                       recv, out_data, e_data[recv]);
                            errors++;
                        end
                        if (out_keep !== e_keep[recv]) begin
                            if (errors < 10)
                                $error("beat %0d keep: got %02h expected %02h",
                                       recv, out_keep, e_keep[recv]);
                            errors++;
                        end
                        if (out_last !== e_last[recv]) begin
                            if (errors < 10)
                                $error("beat %0d last: got %0b expected %0b",
                                       recv, out_last, e_last[recv]);
                            errors++;
                        end
                        recv++;
                    end
                end
                @(posedge clk); #1;
                out_ready = 1'b1;
            end
        join

        if (pulses != NFRAME) begin
            $error("frame_pulse fired %0d times for %0d frames", pulses, NFRAME);
            errors++;
        end

        $display("beats=%0d/%0d frames=%0d errors=%0d",
                 recv, n_exp, pulses, errors);
        if (errors == 0 && recv == n_exp) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    always @(negedge clk) begin
        if (!rst) begin
            if (frame_pulse) pulses++;
            // a bubble inside a body would put a gap in a frame already on the
            // wire, so it must not happen while the producer is feeding one
            if (check_underrun && body_phase && underrun) begin
                if (errors < 10) $error("underrun with the body being fed");
                errors++;
            end
            // the period the pacer sees has to be the one in this frame's header
            if (pace_req && pace_grant) begin
                if (pace_period !== in_data[63:32]) begin
                    $error("pace_period %0d does not match the header %0d",
                           pace_period, in_data[63:32]);
                    errors++;
                end
            end
        end
    end

endmodule
