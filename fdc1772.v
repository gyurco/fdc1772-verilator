//
// fdc1772.v
//
// Copyright (c) 2015 Till Harbaum <till@harbaum.org>
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

// TODO: 
// - Don't directly set track register but control it with the step commands
// - 30ms settle time after step before data can be read
// - some parts are hard coded for archie floppy format (not dos)

module fdc1772 (
		input 	      clkcpu, // system cpu clock.
		input 	      clk8m_en,

		// external set signals 
		input [3:0]   floppy_drive,
		input 	      floppy_side, 
		input 	      floppy_motor,
		input 	      floppy_inuse,
		input 	      floppy_density,
		input 	      floppy_reset,

		// interrupts
		output 	      floppy_firq, // floppy fast irq
		output 	      floppy_drq, // data request interrupt

		// "wishbone bus" the ack is externally generated currently. 
		input 	      wb_cyc,
		input 	      wb_stb,
		input 	      wb_we,

		input [15:2]  wb_adr, // la
		input [7:0]   wb_dat_i, // bd
		output reg [7:0]  wb_dat_o, // bd 

		// place any signals that need to be passed up to the top after here.
		output [31:0] dio_status_out,
		input [31:0]  dio_status_in,
		input 	      dio_in_strobe,
		input [7:0]   dio_in 	     
);

localparam CLK = 8000000;

// -------------------------------------------------------------------------
// --------------------- IO controller status handling ---------------------
// -------------------------------------------------------------------------

// sector only needs 4 bits and track only needs 7 bits. We thus encode side and
// floppy_drive into the upper bits
assign dio_status_out = { 5'b10100, fifo_rptr==0, fifo_wptr==0, busy,
	cmd, floppy_side, track[6:0], floppy_drive, sector[3:0] };

// input status encodes information about all four possible floppy drives
// in 4*8 bits
wire [7:0] floppy_status =
	   (floppy_drive == 4'b0111)?dio_status_in[31:24]:
	   (floppy_drive == 4'b1011)?dio_status_in[23:16]:
	   (floppy_drive == 4'b1101)?dio_status_in[15:8]:
	   (floppy_drive == 4'b1110)?dio_status_in[7:0]:
	   8'h00;

wire floppy_present = floppy_status[0];
wire floppy_write_protected = 1'b1; // will be floppy_status[1] in the future
   
// -------------------------------------------------------------------------
// ---------------------------- IRQ/DRQ handling ---------------------------
// -------------------------------------------------------------------------
reg irq;
reg irq_set;

// floppy_reset and read of status register clears irq
reg cpu_read_status;
always @(posedge clkcpu)
  cpu_read_status <= wb_stb && wb_cyc && !wb_we && 
		     (wb_adr[3:2] == FDC_REG_CMDSTATUS);
   
wire irq_clr = !floppy_reset || cpu_read_status;
   
always @(posedge irq_set or posedge irq_clr) begin
   if(irq_clr) irq <= 1'b0;
   else        irq <= 1'b1;
end
   
assign floppy_firq = irq;
   
reg drq;
reg drq_set;

reg cpu_read_data;
always @(posedge clkcpu)
  cpu_read_data <= wb_stb && wb_cyc && !wb_we && 
		   (wb_adr[3:2] == FDC_REG_DATA);
   
wire drq_clr = !floppy_reset || cpu_read_data;
   
always @(posedge drq_set or posedge drq_clr) begin
   if(drq_clr) drq <= 1'b0;
   else        drq <= 1'b1;
end

assign floppy_drq = drq;

// -------------------------------------------------------------------------
// -------------------- virtual floppy drive mechanics ---------------------
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// ------------------------------- floppy 0 --------------------------------
// -------------------------------------------------------------------------
wire fd_index;
wire fd_ready;
wire [6:0] fd_track;
wire [3:0] fd_sector;
wire fd_sector_hdr;
wire fd_sector_data;
wire fd_dclk;
wire fd_track0 = (fd_track == 0);

floppy floppy0 (.clk         ( clk8m_en       ), 
		.select      ( 1'b1           ),
		.motor_on    ( motor_on       ),
		.step_in     ( step_in        ),
		.step_out    ( step_out       ),
		.dclk        ( fd_dclk        ),
		.track       ( fd_track       ),
		.sector      ( fd_sector      ),
		.sector_hdr  ( fd_sector_hdr  ),
	 	.sector_data ( fd_sector_data ),
		.ready       ( fd_ready       ),
		.index       ( fd_index       )
);

// -------------------------------------------------------------------------
// ----------------------- internal state machines -------------------------
// -------------------------------------------------------------------------

// --------------------------- Motor handling ------------------------------
   
// if motor is off and type 1 command with "spin up sequnce" bit 3 set
// is received then the command is executed after the motor has
// reached full speed for 5 rotations (800ms spin-up time + 5*200ms =
// 1.8sec) If the floppy is idle for 10 rotations (2 sec) then the
// motor is switched off again
localparam MOTOR_IDLE_COUNTER = 10;
reg [3:0] motor_timeout_index;
reg indexD;
reg busy;
reg step_in, step_out;
reg [3:0] motor_spin_up_sequence;

// consider spin up done either if the motor is not supposed to spin at all or
// if it's supposed to run and has left the spin up sequence
wire motor_spin_up_done = (!motor_on) || (motor_on && (motor_spin_up_sequence == 0));

// ---------------------------- step handling ------------------------------

localparam STEP_PULSE_LEN = 1;
localparam STEP_PULSE_CLKS = (STEP_PULSE_LEN * CLK)/1000;
reg [15:0] step_pulse_cnt;

// the step rate is only valid for command type I
wire [15:0] step_rate_clk = 
	   (cmd[1:0]==2'b00)?(2*CLK/1000-1):    // 2ms
	   (cmd[1:0]==2'b01)?(3*CLK/1000-1):    // 3ms
	   (cmd[1:0]==2'b10)?(5*CLK/1000-1):    // 5ms
	   (6*CLK/1000-1);                      // 6ms
	   
reg [15:0] step_rate_cnt;

// flag indicating that a "step" is in progress
wire step_busy = (step_rate_cnt != 0);
reg [7:0] step_to;

always @(posedge clk8m_en) begin
   if(!floppy_reset) begin
      motor_on <= 1'b0;
      busy <= 1'b0;
      step_in <= 1'b0;
      step_out <= 1'b0;
      irq_set <= 1'b0;
      data_read_start_set <= 1'b0;
      data_read_done_clr <= 1'b0;
   end else begin
      irq_set <= 1'b0;
      data_read_start_set <= 1'b0;
      data_read_done_clr <= 1'b0;

      // disable step signal after 1 msec
      if(step_pulse_cnt != 0) 
	step_pulse_cnt <= step_pulse_cnt - 16'd1;
      else begin
 	 step_in <= 1'b0;
 	 step_out <= 1'b0;
      end
   
      // step rate timer
      if(step_rate_cnt != 0) 
	step_rate_cnt <= step_rate_cnt - 16'd1;

      // just received a new command
      if(cmd_rx) begin
	 busy <= 1'b1;

	 // type I commands can wait for the disk to spin up
	 if(cmd_type_1 && cmd[3] && !motor_on) begin
	    motor_on <= 1'b1;
	    motor_spin_up_sequence <= 6;   // wait for 6 full rotations
	 end

	 // handle "forced interrupt"
	 if(cmd[7:4] == 4'b1101) begin
	    busy <= 1'b0;
	    if(cmd[3]) irq_set <= 1'b1;
	 end
      end

      // execute command if motor is not supposed to be running or
      // wait for motor spinup to finish
      if(busy && motor_spin_up_done && !step_busy) begin

	 // ------------------------ TYPE I -------------------------
	 if(cmd_type_1) begin
	    // all type 1 commands are step commands and step_to has been set
	    if(fd_track == step_to) begin
	       busy <= 1'b0;   // done if reached track 0
	       motor_timeout_index <= MOTOR_IDLE_COUNTER - 1;
	       irq_set <= 1'b1; // emit irq when command done
	    end else begin
	       // do the step
	       if(step_to < fd_track) step_in  <= 1'b1;
	       else                   step_out  <= 1'b1;
	       
	       // update track register
//	       if( (!cmd[6] && !cmd[5]) ||               // restore/seek
//		   ((cmd[6] || cmd[5]) && cmd[4])) begin // step(in/out) with update flag
//		  if(step_to < fd_track) track <= track - 1'd0;
//		  else                   track <= track + 1'd0;
//	       end
		 
	       step_pulse_cnt <= STEP_PULSE_CLKS-1;
	       step_rate_cnt <= step_rate_clk;
	    end
	 end // if (cmd_type_1)

	 // ------------------------ TYPE II -------------------------
	 if(cmd_type_2) begin
	    // read sector
	    if(cmd[7:5] == 3'b100) begin
	       // we are busy until the right sector header passes under 
	       // the head and the arm7 has delivered at least one byte
	       // (one byte is sufficient as the arm7 is much faster and
	       // all further bytes will arrive in time)
	       if(fd_ready && fd_sector_hdr && 
		  (fd_sector == sector) && (fifo_wptr != 0))
		  data_read_start_set <= 1'b1;

	       if(data_read_done) begin
		  data_read_done_clr <= 1'b1;
		  busy <= 1'b0;
 		  motor_timeout_index <= MOTOR_IDLE_COUNTER - 1;
		  irq_set <= 1'b1; // emit irq when command done
	       end
	    end
	 end

	 // ------------------------ TYPE III -------------------------
	 if(cmd_type_3) begin
	    // read address
	    if(cmd[7:4] == 4'b1100) begin
	       // we are busy until the next setor header passes under the head
	       if(fd_ready && fd_sector_hdr)
		  data_read_start_set <= 1'b1;

	       if(data_read_done) begin
		  data_read_done_clr <= 1'b1;
		  busy <= 1'b0;
 		  motor_timeout_index <= MOTOR_IDLE_COUNTER - 1;
		  irq_set <= 1'b1; // emit irq when command done
	       end
	    end
	 end
      end
	 
      // stop motor if there was no command for 10 index pulses
      indexD <= fd_index;
      if(indexD && !fd_index) begin
	 // led motor timeout run once fdc is not busy anymore
	 if(!busy) begin
	    if(motor_timeout_index != 0)
	      motor_timeout_index <= motor_timeout_index - 4'd1;
	    else
	      motor_on <= 1'b0;
	 end

	 if(motor_spin_up_sequence != 0)
	   motor_spin_up_sequence <= motor_spin_up_sequence - 4'd1;
      end
   end
end

// floppy delivers data at a floppy generated rate (usually 250kbit/s), so the start and stop
// signals need to be passed forth and back from cpu clock domain to floppy data clock domain
reg data_read_start_set;
reg data_read_start_clr;
reg data_read_start;
always @(posedge data_read_start_set or posedge data_read_start_clr) begin
   if(data_read_start_clr) data_read_start <= 1'b0;
   else                    data_read_start <= 1'b1;
end

reg data_read_done_set;
reg data_read_done_clr;
reg data_read_done;
always @(posedge data_read_done_set or posedge data_read_done_clr) begin
   if(data_read_done_clr) data_read_done <= 1'b0;
   else                   data_read_done <= 1'b1;
end

// ==================================== FIFO ==================================
   
// 1 kB buffer used to receive a sector as fast as possible from from the io
// controller. The internal transfer afterwards then runs at 250000 Bit/s
reg [7:0] fifo [1023:0];
reg [10:0] fifo_rptr;
reg [10:0] fifo_wptr;

// -------------------- data write -----------------------
   
always @(posedge dio_in_strobe or posedge cmd_rx) begin
   if(cmd_rx)
     fifo_wptr <= 11'd0;
   else begin
      if(fifo_wptr != 11'd1024) begin
	 fifo[fifo_wptr] <= dio_in;
	 fifo_wptr <= fifo_wptr + 11'd1;
      end
   end
end
   
// -------------------- data read -----------------------

reg dclkD;
reg [10:0] data_read_cnt;
always @(posedge clkcpu) begin
   // reset fifo read pointer on reception of a new command
   if(cmd_rx)
     fifo_rptr <= 11'd0;

   data_read_start_clr <= 1'b0;
   data_read_done_set <= 1'b0;
   drq_set <= 1'b0;

   // received request to read data
   if(data_read_start) begin
      data_read_start_clr <= 1'b1;

      // read_address command has 6 data bytes
      if(cmd[7:4] == 4'b1100)
	data_read_cnt <= 11'd6+11'd1;

      // read sector has 1024 data bytes
      if(cmd[7:5] == 3'b100)
	data_read_cnt <= 11'd1024+11'd1;
   end

   // rising edge of floppy data clock (fd_dclk)
   dclkD <= fd_dclk;
   if(fd_dclk && !dclkD) begin
      if(data_read_cnt != 0) begin
	 if(data_read_cnt != 1) begin
	    drq_set <= 1'b1;
	    // read_address
	    if(cmd[7:4] == 4'b1100) begin
	       case(data_read_cnt)
		 7: data_out <= fd_track;
		 6: data_out <= { 7'b0000000, floppy_side };
		 5: data_out <= fd_sector;
		 4: data_out <= 8'd3; // TODO: sec size 0=128, 1=256, 2=512, 3=1024
		 3: data_out <= 8'ha5;
		 2: data_out <= 8'h5a;
	       endcase // case (data_read_cnt)
	    end
	    
	    // read sector
	    if(cmd[7:5] == 3'b100) begin
	       if(fifo_rptr != 11'd1024) begin
		  data_out <= fifo[fifo_rptr];
		  fifo_rptr <= fifo_rptr + 11'd1;
	       end
	    end
	 end
	    
	 // count down and stop after last byte
	 data_read_cnt <= data_read_cnt - 11'd1;
	 if(data_read_cnt == 1)
	   data_read_done_set <= 1'b1;
      end
   end
end
   
// the status byte
wire [7:0] status = { motor_on, 
		      1'b0,               // wrprot
		      cmd_type_1?motor_spin_up_done:1'b0,  // data mark
		      1'b0,               // record not found
		      1'b0,               // crc error
		      cmd_type_1?(fd_track == 0):1'b0,
		      cmd_type_1?~fd_index:floppy_drq,
		      busy };

reg [7:0] track;
reg [7:0] sector;
reg [7:0] data_in;
reg [7:0] data_out;

reg step_dir;
reg motor_on;

// ---------------------------- command register -----------------------   
reg [7:0] cmd;
wire cmd_type_1 = (cmd[7] == 1'b0);
wire cmd_type_2 = (cmd[7:6] == 2'b10);
wire cmd_type_3 = (cmd[7:5] == 3'b111) || (cmd[7:4] == 4'b1100);
wire cmd_type_4 = (cmd[7:4] == 4'b1101);

localparam FDC_REG_CMDSTATUS    = 0;
localparam FDC_REG_TRACK        = 1;
localparam FDC_REG_SECTOR       = 2;
localparam FDC_REG_DATA         = 3;

// CPU register read
always @(wb_stb, wb_cyc, wb_adr, wb_we) begin
   wb_dat_o = 8'h00;

   if(wb_stb && wb_cyc && !wb_we) begin
      case(wb_adr[3:2])
        FDC_REG_CMDSTATUS: wb_dat_o = status;
        FDC_REG_TRACK:     wb_dat_o = track;
        FDC_REG_SECTOR:    wb_dat_o = sector;
        FDC_REG_DATA:      wb_dat_o = data_out;
      endcase
   end
end

// cpu register write
reg cmd_rx;
reg last_stb;
   
always @(posedge clkcpu) begin
   if(!floppy_reset) begin
      // clear internal registers
      cmd <= 8'h00;
      track <= 8'h00;
      sector <= 8'h00;

      // reset state machines and counters
      cmd_rx <= 1'b0;
      last_stb <= 1'b0;
   end else begin
      last_stb <= wb_stb;

      // command reception is ack'd by fdc going busy
      if(busy)
	cmd_rx <= 1'b0;

      // only react if stb just raised
      if(!last_stb && wb_stb && wb_cyc && wb_we) begin
	 if(wb_adr[3:2] == FDC_REG_CMDSTATUS) begin       // command register
            cmd <= wb_dat_i;
	    cmd_rx <= 1'b1;
	    
            // ------------- TYPE I commands -------------
            if(wb_dat_i[7:4] == 4'b0000) begin               // RESTORE
	       step_to <= 8'd0;
	       track <= 8'd0;
            end
            
            if(wb_dat_i[7:4] == 4'b0001) begin               // SEEK
	       step_to <= data_in;
	       track <= data_in;
            end
            
            if(wb_dat_i[7:5] == 3'b001) begin                // STEP
	       step_to <= (step_dir == 1)?(track + 8'd1):(track - 8'd1);
	       if(wb_dat_i[4]) track <= (step_dir == 1)?(track + 8'd1):(track - 8'd1);
            end
            
            if(wb_dat_i[7:5] == 3'b010) begin                // STEP-IN
	       step_to <= track + 8'd1;
               step_dir <= 1'b1;
	       if(wb_dat_i[4]) track <= track + 8'd1;
            end
	    
            if(wb_dat_i[7:5] == 3'b011) begin                // STEP-OUT
	       step_to <= track - 8'd1;
               step_dir <= 1'b0;
	       if(wb_dat_i[4]) track <= track - 8'd1;
            end
            
            // ------------- TYPE II commands -------------
            if(wb_dat_i[7:5] == 3'b100) begin                // read sector
            end

            if(wb_dat_i[7:5] == 3'b101) begin                // write sector
	    end
            
            // ------------- TYPE III commands ------------
            if(wb_dat_i[7:4] == 4'b1100) begin               // read address
	    end
	       
            if(wb_dat_i[7:4] == 4'b1110) begin               // read track
	    end
            
            if(wb_dat_i[7:4] == 4'b1111) begin               // write track
	    end
	       
            // ------------- TYPE IV commands -------------
            if(wb_dat_i[7:4] == 4'b1101) begin               // force intrerupt
            end
         end
	 
         if(wb_adr[3:2] == FDC_REG_TRACK)                    // track register
           track <= wb_dat_i;
         
         if(wb_adr[3:2] == FDC_REG_SECTOR)                   // sector register
           sector <= wb_dat_i;

         if(wb_adr[3:2] == FDC_REG_DATA)                     // data register
           data_in <= wb_dat_i;
      end
   end
end

endmodule
