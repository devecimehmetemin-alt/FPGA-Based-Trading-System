module tb_mold_deframe();

    localparam int MAXB = 32768;
    localparam int MAXBY = 262144;
    localparam int MAXM = 8192;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, in_valid, in_last, in_fcs_ok;
    logic [63:0] in_data;
    logic [7:0] in_keep;
    logic msg_valid, msg_start, msg_last, pkt_bad;
    logic [127:0] msg_data;
    logic [15:0] msg_keep;
    logic [15:0] msg_len;
    logic [63:0] msg_seq;

    logic [79:0] mbeat [0:MAXB-1];
    logic [7:0] ebyte [0:MAXBY-1];
    int exp_off [0:MAXM-1];
    int exp_len [0:MAXM-1];
    logic [63:0] exp_seq [0:MAXM-1];

    int n_beat = 0, n_byte = 0, n_msg = 0, p = 0, m = 0, errors = 0;
    int fd, code, off, len;
    logic [63:0] seq;
    string kind;

    mold_deframe DUT(.*);

    initial begin
        $readmemh("mold_beats.hex", mbeat);
        $readmemh("itch_expect.hex", ebyte);
        while (n_beat < MAXB && !$isunknown(mbeat[n_beat])) n_beat++;
        while (n_byte < MAXBY && !$isunknown(ebyte[n_byte])) n_byte++;

        fd = $fopen("itch_expect.txt", "r");
        if (fd == 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "cannot open itch_expect.txt");
        end
        forever begin
            code = $fscanf(fd, "%d %d %d %s\n", off, len, seq, kind);
            if (code != 4) break;
            exp_off[n_msg] = off;
            exp_len[n_msg] = len;
            exp_seq[n_msg] = seq;
            n_msg++;
        end
        $fclose(fd);
        $display("loaded %0d beats, %0d golden bytes, %0d messages", n_beat, n_byte, n_msg);

        rst = 1; in_valid = 0; in_data = '0; in_keep = '0; in_last = 0; in_fcs_ok = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        for (int i = 0; i < n_beat; i++) begin
            @(posedge clk); #1;
            {in_last, in_keep, in_data} = mbeat[i][72:0];
            in_valid = 1; in_fcs_ok = 1;
        end
        @(posedge clk); #1;
        in_valid = 0; in_last = 0;
        repeat (20) @(posedge clk);

        @(posedge clk); #1;
        in_valid = 1; in_last = 1; in_fcs_ok = 0; in_keep = 8'b11111111; in_data = '0;
        #1 if (!pkt_bad) begin
            $error("pkt_bad low on a last beat with in_fcs_ok=0");
            errors++;
        end
        @(posedge clk); #1;
        in_valid = 0; in_last = 0;
        repeat (4) @(posedge clk);

        $display("checked=%0d/%0d messages %0d/%0d bytes errors=%0d", m, n_msg, p, n_byte, errors);
        if (errors == 0 && m == n_msg && p == n_byte && m > 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    always @(negedge clk) begin
        if (msg_valid) begin
            if (m >= n_msg) begin
                if (errors < 10) $error("output past the end of the golden vector");
                errors++;
            end else begin
                if (msg_start !== (p == exp_off[m])) begin
                    if (errors < 10)
                        $error("msg %0d byte %0d: msg_start=%0b at offset %0d, expected offset %0d",
                               m, p, msg_start, p, exp_off[m]);
                    errors++;
                end
                if (msg_len !== exp_len[m]) begin
                    if (errors < 10)
                        $error("msg %0d: msg_len=%0d expected %0d", m, msg_len, exp_len[m]);
                    errors++;
                end
                if (msg_seq !== exp_seq[m]) begin
                    if (errors < 10)
                        $error("msg %0d: msg_seq=%0d expected %0d", m, msg_seq, exp_seq[m]);
                    errors++;
                end
                for (int i = 0; i < 16; i++) begin
                    if (msg_keep[i]) begin
                        if (p >= n_byte) begin
                            if (errors < 10) $error("msg %0d: byte %0d past the golden vector", m, p);
                            errors++;
                        end else if (msg_data[8*i +: 8] !== ebyte[p]) begin
                            if (errors < 10)
                                $error("msg %0d byte %0d: got %02h expected %02h",
                                       m, p, msg_data[8*i +: 8], ebyte[p]);
                            errors++;
                        end
                        p++;
                    end
                end
                if (msg_last) begin
                    if (p != exp_off[m] + exp_len[m]) begin
                        if (errors < 10)
                            $error("msg %0d: ended at byte %0d expected %0d",
                                   m, p, exp_off[m] + exp_len[m]);
                        errors++;
                    end
                    m++;
                end
            end
        end
    end

endmodule
