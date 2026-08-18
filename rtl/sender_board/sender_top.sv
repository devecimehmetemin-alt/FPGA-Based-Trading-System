`default_nettype none

// Sender board replay engine: DDR extents in, paced 64 bit frames out to the 10G MAC.

module sender_top #(
    parameter int ADDR_W = 40,
    parameter int AXI_DATA_W = 128,
    parameter int ID_W = 4,
    parameter int NUM_EXTENTS = 2,
    parameter int BURST_BEATS = 16,
    parameter int FIFO_ADDR_W = 8
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic start,
    input wire logic [NUM_EXTENTS-1:0][ADDR_W-1:0] ext_base,
    input wire logic [NUM_EXTENTS-1:0][31:0] ext_beats,
    input wire logic [$clog2(NUM_EXTENTS+1)-1:0] ext_count,
    output logic [ID_W-1:0] m_axi_arid,
    output logic [ADDR_W-1:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arvalid,
    input wire logic m_axi_arready,
    input wire logic [AXI_DATA_W-1:0] m_axi_rdata,
    input wire logic [1:0] m_axi_rresp,
    input wire logic m_axi_rlast,
    input wire logic m_axi_rvalid,
    output logic m_axi_rready,
    output logic tx_valid,
    output logic [63:0] tx_data,
    output logic [7:0] tx_keep,
    output logic tx_last,
    input wire logic tx_ready,
    output logic busy,
    output logic done,
    output logic [31:0] frames_sent,
    output logic underrun,
    output logic resp_err,
    output logic fifo_overflow
);

    localparam int FIFO_DEPTH = 1 << FIFO_ADDR_W;

    logic rd_valid, rd_ready, wr_valid, wr_ready, fifo_full_err;
    logic [AXI_DATA_W-1:0] wr_data, rd_data;
    logic [FIFO_ADDR_W:0] level;
    logic [15:0] space;
    logic narrow_valid, narrow_ready;
    logic [63:0] narrow_data;
    logic pace_req, pace_grant;
    logic [31:0] pace_period;
    logic frame_pulse, underrun_now;

    assign space = 16'(FIFO_DEPTH) - 16'(level);

    axi_read_stream #(
        .ADDR_W(ADDR_W),
        .DATA_W(AXI_DATA_W),
        .ID_W(ID_W),
        .NUM_EXTENTS(NUM_EXTENTS),
        .BURST_BEATS(BURST_BEATS)
    ) u_read (
        .clk(clk),
        .rst(rst),
        .start(start),
        .ext_base(ext_base),
        .ext_beats(ext_beats),
        .ext_count(ext_count),
        .space(space),
        .busy(busy),
        .done(done),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .out_valid(wr_valid),
        .out_data(wr_data),
        .out_ready(wr_ready),
        .resp_err(resp_err)
    );

    sync_fifo #(
        .DATA_W(AXI_DATA_W),
        .ADDR_W(FIFO_ADDR_W)
    ) u_fifo (
        .clk(clk),
        .rst(rst),
        .wr_valid(wr_valid),
        .wr_data(wr_data),
        .wr_ready(wr_ready),
        .rd_ready(rd_ready),
        .rd_valid(rd_valid),
        .rd_data(rd_data),
        .level(level),
        .overflow(fifo_full_err)
    );

    axis_narrow #(
        .WIDE_W(AXI_DATA_W)
    ) u_narrow (
        .clk(clk),
        .rst(rst),
        .in_valid(rd_valid),
        .in_data(rd_data),
        .in_ready(rd_ready),
        .out_valid(narrow_valid),
        .out_data(narrow_data),
        .out_ready(narrow_ready)
    );

    frame_pacer u_pacer (
        .clk(clk),
        .rst(rst),
        .req(pace_req),
        .period(pace_period),
        .grant(pace_grant)
    );

    frame_unpack u_unpack (
        .clk(clk),
        .rst(rst),
        .in_valid(narrow_valid),
        .in_data(narrow_data),
        .in_ready(narrow_ready),
        .pace_req(pace_req),
        .pace_period(pace_period),
        .pace_grant(pace_grant),
        .out_valid(tx_valid),
        .out_data(tx_data),
        .out_keep(tx_keep),
        .out_last(tx_last),
        .out_ready(tx_ready),
        .frame_pulse(frame_pulse),
        .underrun(underrun_now)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            frames_sent <= '0;
            underrun <= 1'b0;
            fifo_overflow <= 1'b0;
        end else begin
            if (start & ~busy) begin
                frames_sent <= '0;
                underrun <= 1'b0;
                fifo_overflow <= 1'b0;
            end else begin
                if (frame_pulse) frames_sent <= frames_sent + 32'd1;
                if (underrun_now) underrun <= 1'b1;
                if (fifo_full_err) fifo_overflow <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
