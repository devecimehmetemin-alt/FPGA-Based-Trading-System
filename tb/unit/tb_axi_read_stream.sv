module tb_axi_read_stream();

    localparam int ADDR_W = 40;
    localparam int DATA_W = 128;
    localparam int ID_W = 4;
    localparam int NUM_EXTENTS = 2;
    localparam int BURST_BEATS = 16;
    localparam int BURST_BYTES = BURST_BEATS * (DATA_W / 8);

    // deep enough for a few bursts, shallow enough that the space guard has to
    // throttle rather than never being reached
    localparam int FIFO_DEPTH = 64;

    localparam logic [ADDR_W-1:0] BASE0 = 40'h00_0000_1000;
    localparam logic [ADDR_W-1:0] BASE1 = 40'h00_0002_0000;
    localparam int BEATS0 = 64;
    localparam int BEATS1 = 96;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, start, busy, done, resp_err;
    logic [NUM_EXTENTS-1:0][ADDR_W-1:0] ext_base;
    logic [NUM_EXTENTS-1:0][31:0] ext_beats;
    logic [$clog2(NUM_EXTENTS+1)-1:0] ext_count;
    logic [15:0] space;
    logic [ID_W-1:0] m_axi_arid;
    logic [ADDR_W-1:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst, m_axi_rresp;
    logic m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
    logic [DATA_W-1:0] m_axi_rdata, out_data;
    logic out_valid, out_ready;

    int errors = 0, got = 0;
    int fifo_level = 0;
    bit inject_err = 0;
    bit checking = 0;

    // the slave answers from a pattern rather than an array, so the extents can
    // sit far apart without a sparse memory model
    function automatic logic [DATA_W-1:0] pattern(input logic [ADDR_W-1:0] a);
        logic [31:0] k;
        k = a[31:0];
        return {~k, k ^ 32'h5A5A_5A5A, k + 32'h1234_5678, k};
    endfunction

    axi_read_stream #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W),
        .ID_W(ID_W),
        .NUM_EXTENTS(NUM_EXTENTS),
        .BURST_BEATS(BURST_BEATS)
    ) DUT (.*);

    // ---- AXI read slave ----------------------------------------------------
    logic [ADDR_W-1:0] q_addr [$];
    logic [7:0] q_len [$];
    logic [ADDR_W-1:0] r_addr;
    logic [8:0] r_left;
    logic r_busy, r_stall, arready_r;

    assign m_axi_arready = arready_r;
    assign m_axi_rvalid = r_busy & ~r_stall;
    assign m_axi_rdata = pattern(r_addr);
    assign m_axi_rlast = r_busy & (r_left == 9'd1);
    assign m_axi_rresp = inject_err ? 2'b10 : 2'b00;

    always_ff @(posedge clk) begin
        if (rst) begin
            arready_r <= 1'b0;
            r_busy <= 1'b0;
            r_stall <= 1'b0;
            r_left <= '0;
            q_addr.delete();
            q_len.delete();
        end else begin
            arready_r <= ($urandom_range(0, 9) < 7);
            r_stall <= ($urandom_range(0, 9) < 2);

            if (m_axi_arvalid && m_axi_arready) begin
                q_addr.push_back(m_axi_araddr);
                q_len.push_back(m_axi_arlen);
            end

            if (!r_busy) begin
                if (q_addr.size() > 0) begin
                    r_addr <= q_addr.pop_front();
                    r_left <= 9'(q_len.pop_front()) + 9'd1;
                    r_busy <= 1'b1;
                end
            end else if (m_axi_rvalid && m_axi_rready) begin
                if (r_left == 9'd1) begin
                    r_busy <= 1'b0;
                end else begin
                    r_left <= r_left - 9'd1;
                    r_addr <= r_addr + ADDR_W'(DATA_W / 8);
                end
            end
        end
    end

    // ---- downstream fifo model ---------------------------------------------
    // out_ready mirrors sync_fifo's wr_ready, so if the space guard is wrong the
    // read master gets back-pressured and the assertion below fires
    assign out_ready = (fifo_level < FIFO_DEPTH);
    assign space = 16'(FIFO_DEPTH - fifo_level);

    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_level <= 0;
        end else begin
            int add, sub;
            add = (out_valid && out_ready) ? 1 : 0;
            sub = (fifo_level > 0 && ($urandom_range(0, 9) < 5)) ? 1 : 0;
            fifo_level <= fifo_level + add - sub;
        end
    end

    // ---- checks ------------------------------------------------------------
    int ar_seen = 0;
    logic [ADDR_W-1:0] want_ar;

    always @(negedge clk) begin
        if (!rst && checking) begin
            if (m_axi_arvalid && m_axi_arready) begin
                if (m_axi_araddr !== want_ar) begin
                    if (errors < 10)
                        $error("ar %0d addr: got %010h expected %010h",
                               ar_seen, m_axi_araddr, want_ar);
                    errors++;
                end
                if (m_axi_arlen !== 8'(BURST_BEATS - 1)) begin
                    $error("ar %0d len %0d, expected %0d",
                           ar_seen, m_axi_arlen, BURST_BEATS - 1);
                    errors++;
                end
                if (m_axi_arsize !== 3'd4 || m_axi_arburst !== 2'b01) begin
                    $error("ar %0d size %0d burst %0b, expected 4 and INCR",
                           ar_seen, m_axi_arsize, m_axi_arburst);
                    errors++;
                end
                // AXI forbids a burst crossing a 4 KB boundary, and a 256 byte
                // burst only obeys that if the extent base is aligned
                if (((m_axi_araddr % 4096) + BURST_BYTES) > 4096) begin
                    $error("ar %0d at %010h crosses a 4 KB boundary",
                           ar_seen, m_axi_araddr);
                    errors++;
                end
                ar_seen++;
                want_ar = (ar_seen == BEATS0 / BURST_BEATS)
                        ? BASE1 : (want_ar + ADDR_W'(BURST_BYTES));
            end

            // the whole point of the space handshake: never stalled by the sink
            if (out_valid && !out_ready) begin
                if (errors < 10)
                    $error("read data stalled with the fifo full, space guard failed");
                errors++;
            end
            if (fifo_level > FIFO_DEPTH) begin
                $error("fifo model overflowed to %0d", fifo_level);
                errors++;
            end

            if (out_valid && out_ready) begin
                logic [ADDR_W-1:0] a;
                a = (got < BEATS0) ? (BASE0 + ADDR_W'(16 * got))
                                   : (BASE1 + ADDR_W'(16 * (got - BEATS0)));
                if (out_data !== pattern(a)) begin
                    if (errors < 10)
                        $error("beat %0d: got %032h expected %032h",
                               got, out_data, pattern(a));
                    errors++;
                end
                got++;
            end
        end
    end

    initial begin
        int guard;

        rst = 1; start = 0; inject_err = 0; checking = 0;
        ext_base[0] = BASE0; ext_base[1] = BASE1;
        ext_beats[0] = 32'(BEATS0); ext_beats[1] = 32'(BEATS1);
        ext_count = 2'd2;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        repeat (2) @(posedge clk);

        if (busy || done) begin
            $error("busy or done set before start");
            errors++;
        end

        want_ar = BASE0;
        checking = 1;
        @(posedge clk); #1;
        start = 1'b1;
        @(posedge clk); #1;
        start = 1'b0;

        guard = 0;
        while (!done && guard < 200000) begin
            @(posedge clk);
            guard++;
        end
        checking = 0;

        if (guard >= 200000) begin
            $error("never finished, %0d of %0d beats", got, BEATS0 + BEATS1);
            errors++;
        end
        if (busy) begin
            $error("still busy after done");
            errors++;
        end
        if (got != BEATS0 + BEATS1) begin
            $error("delivered %0d beats, expected %0d", got, BEATS0 + BEATS1);
            errors++;
        end
        if (ar_seen != (BEATS0 + BEATS1) / BURST_BEATS) begin
            $error("issued %0d bursts, expected %0d",
                   ar_seen, (BEATS0 + BEATS1) / BURST_BEATS);
            errors++;
        end
        if (resp_err) begin
            $error("resp_err set on a clean run");
            errors++;
        end

        // a slave error has to be latched: a replay built on a bad read would put
        // corrupt frames on the wire and look like a receiver fault
        repeat (4) @(posedge clk);
        inject_err = 1;
        @(posedge clk); #1;
        start = 1'b1;
        @(posedge clk); #1;
        start = 1'b0;
        guard = 0;
        while (!done && guard < 200000) begin
            @(posedge clk);
            guard++;
        end
        if (!resp_err) begin
            $error("resp_err clear after a slave error response");
            errors++;
        end

        $display("beats=%0d bursts=%0d errors=%0d", got, ar_seen, errors);
        if (errors == 0 && got == BEATS0 + BEATS1) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

endmodule
