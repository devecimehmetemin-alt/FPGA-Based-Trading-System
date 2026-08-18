// The sender replays a DDR image built from the very frames tb_header_strip and
// tb_book_top consume, so what leaves this board must be eth_beats.hex byte for
// byte. That is the whole two board demo checked before either board exists.

module tb_sender_top();

    localparam int ADDR_W = 40;
    localparam int AXI_DATA_W = 128;
    localparam int ID_W = 4;
    localparam int NUM_EXTENTS = 2;
    localparam int BURST_BEATS = 16;
    localparam int BURST_BYTES = BURST_BEATS * (AXI_DATA_W / 8);
    localparam int FIFO_ADDR_W = 8;

    localparam int MAXW = 262144;
    localparam int MAXB = 1048576;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, start, busy, done, underrun, resp_err, fifo_overflow;
    logic [NUM_EXTENTS-1:0][ADDR_W-1:0] ext_base;
    logic [NUM_EXTENTS-1:0][31:0] ext_beats;
    logic [$clog2(NUM_EXTENTS+1)-1:0] ext_count;
    logic [ID_W-1:0] m_axi_arid;
    logic [ADDR_W-1:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst, m_axi_rresp;
    logic m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
    logic [AXI_DATA_W-1:0] m_axi_rdata;
    logic tx_valid, tx_last, tx_ready;
    logic [63:0] tx_data;
    logic [7:0] tx_keep;
    logic [31:0] frames_sent;

    logic [127:0] img [0:MAXW-1];
    logic [79:0] ebeat [0:MAXB-1];

    int n_frames, slack, beats0, beats1, n_tx;
    longint base0, base1;
    int n_exp = 0, got = 0, errors = 0, frames_seen = 0;

    // pacing is measured start to start, so the check is on the first beat of
    // each frame rather than on the gap left after the last
    bit at_frame_start = 1;
    int last_start = 0, cycle = 0, frame_beats = 0, early = 0;
    int worst_late = 0, late_frames = 0;

    sender_top #(
        .ADDR_W(ADDR_W),
        .AXI_DATA_W(AXI_DATA_W),
        .ID_W(ID_W),
        .NUM_EXTENTS(NUM_EXTENTS),
        .BURST_BEATS(BURST_BEATS),
        .FIFO_ADDR_W(FIFO_ADDR_W)
    ) DUT (.*);

    // ---- AXI read slave over the replay image ------------------------------
    logic [ADDR_W-1:0] q_addr [$];
    logic [7:0] q_len [$];
    logic [ADDR_W-1:0] r_addr;
    logic [8:0] r_left;
    logic r_busy, r_stall, arready_r;

    assign m_axi_arready = arready_r;
    assign m_axi_rvalid = r_busy & ~r_stall;
    assign m_axi_rdata = img[r_addr >> 4];
    assign m_axi_rlast = r_busy & (r_left == 9'd1);
    assign m_axi_rresp = 2'b00;

    always_ff @(posedge clk) begin
        if (rst) begin
            arready_r <= 1'b0;
            r_busy <= 1'b0;
            r_stall <= 1'b0;
            r_left <= '0;
            q_addr.delete();
            q_len.delete();
        end else begin
            arready_r <= ($urandom_range(0, 9) < 8);
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
                    r_addr <= r_addr + ADDR_W'(AXI_DATA_W / 8);
                end
            end
        end
    end

    // a real 10G MAC takes a beat every cycle and cannot push back
    assign tx_ready = 1'b1;

    initial begin
        int fd, guard;

        $readmemh("sender_image.mem", img);

        fd = $fopen("sender_meta.txt", "r");
        if (fd == 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "cannot open sender_meta.txt, run scripts/build_sender_vectors.py");
        end
        if ($fscanf(fd, "%d %d %d %d %d %d %d",
                    n_frames, slack, base0, beats0, base1, beats1, n_tx) != 7) begin
            $display("RESULT: FAIL");
            $fatal(1, "sender_meta.txt is malformed");
        end
        $fclose(fd);

        $readmemh("eth_beats.hex", ebeat);
        while (n_exp < MAXB && !$isunknown(ebeat[n_exp])) n_exp++;
        // only the leading frames of the reference are packed into the image
        if (n_tx > n_exp) begin
            $display("RESULT: FAIL");
            $fatal(1, "image holds %0d beats, eth_beats.hex only has %0d", n_tx, n_exp);
        end
        n_exp = n_tx;
        $display("image %0d + %0d beats, %0d frames, %0d reference beats",
                 beats0, beats1, n_frames, n_exp);

        rst = 1; start = 0;
        ext_base[0] = ADDR_W'(base0);
        ext_base[1] = ADDR_W'(base1);
        ext_beats[0] = 32'(beats0);
        ext_beats[1] = 32'(beats1);
        ext_count = 2'd2;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        repeat (2) @(posedge clk);

        @(posedge clk); #1;
        start = 1'b1;
        @(posedge clk); #1;
        start = 1'b0;

        guard = 0;
        while (!(done && frames_seen == n_frames) && guard < 4000000) begin
            @(posedge clk);
            guard++;
        end
        repeat (20) @(posedge clk);

        if (guard >= 4000000) begin
            $error("never finished, %0d frames and %0d beats out", frames_seen, got);
            errors++;
        end
        if (frames_sent != 32'(n_frames)) begin
            $error("frames_sent %0d, expected %0d", frames_sent, n_frames);
            errors++;
        end
        // any of these means the wire got something the receiver never validated
        if (underrun) begin
            $error("underrun: a frame went out with a hole in it");
            errors++;
        end
        if (fifo_overflow) begin
            $error("fifo overflow: the space guard let the read path run ahead");
            errors++;
        end
        if (resp_err) begin
            $error("resp_err set on a clean slave");
            errors++;
        end
        if (early != 0) begin
            $error("%0d frames left earlier than their period allowed", early);
            errors++;
        end

        $display("beats=%0d/%0d frames=%0d/%0d late=%0d worst_late=%0d errors=%0d",
                 got, n_exp, frames_seen, n_frames, late_frames, worst_late, errors);
        if (errors == 0 && got == n_exp && frames_seen == n_frames)
            $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    always @(negedge clk) begin
        if (!rst) begin
            cycle++;

            // AXI forbids a burst crossing a 4 KB boundary, which holds only while
            // every extent base is page aligned
            if (m_axi_arvalid && m_axi_arready
                && (((m_axi_araddr % 4096) + BURST_BYTES) > 4096)) begin
                if (errors < 15)
                    $error("burst at %010h crosses a 4 KB boundary", m_axi_araddr);
                errors++;
            end

            if (tx_valid && tx_ready) begin
                if (got >= n_exp) begin
                    if (errors < 15) $error("beat %0d past the reference", got);
                    errors++;
                end else begin
                    if (tx_data !== ebeat[got][63:0]) begin
                        if (errors < 15)
                            $error("beat %0d data: got %016h expected %016h",
                                   got, tx_data, ebeat[got][63:0]);
                        errors++;
                    end
                    if (tx_keep !== ebeat[got][71:64]) begin
                        if (errors < 15)
                            $error("beat %0d keep: got %02h expected %02h",
                                   got, tx_keep, ebeat[got][71:64]);
                        errors++;
                    end
                    if (tx_last !== ebeat[got][72]) begin
                        if (errors < 15)
                            $error("beat %0d last: got %0b expected %0b",
                                   got, tx_last, ebeat[got][72]);
                        errors++;
                    end
                end
                got++;

                if (at_frame_start) begin
                    if (frames_seen > 0) begin
                        // period is the frame's own beats plus the slack the image
                        // was built with, so a shorter gap means the link is being
                        // driven faster than the plan asked for
                        int want, spacing;
                        want = frame_beats + slack;
                        spacing = cycle - last_start;
                        if (spacing < want) begin
                            if (early < 5)
                                $error("frame %0d started %0d cycles after the last, period was %0d",
                                       frames_seen, spacing, want);
                            early++;
                        end else if (spacing > want) begin
                            late_frames++;
                            if ((spacing - want) > worst_late)
                                worst_late = spacing - want;
                        end
                    end
                    last_start = cycle;
                    frame_beats = 0;
                    at_frame_start = 0;
                end
                frame_beats++;

                if (tx_last) begin
                    frames_seen++;
                    at_frame_start = 1;
                end
            end
        end
    end

endmodule
